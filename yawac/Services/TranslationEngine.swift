import Foundation
import MLXLLM
import MLXLMCommon

/// Lifecycle state of a `TranslationEngine`.
enum TranslationEngineState: Equatable {
    case unloaded
    case loading
    case ready
    case failed(String)
}

/// Protocol surface consumed by the translation view-model (T6).
protocol TranslationEngineProtocol: Sendable {
    var stateSnapshot: TranslationEngineState { get async }
    func load(modelDir: URL) async throws
    func translate(_ text: String,
                   from source: String,
                   to target: String) async throws -> String
}

enum TranslationError: Error {
    case notReady
}

/// Concrete MLX-backed engine.
///
/// MLX 2.29.1 exposes `loadModelContainer(directory:)` (free function in
/// `MLXLMCommon`) which short-circuits the Hub download when given a
/// local URL — see `MLXLMCommon/Load.swift::downloadModel`. That is how
/// we avoid hitting the network at engine load time; the model bytes are
/// expected to already exist on disk thanks to
/// `TranslationModelManager`.
///
/// Generation uses the high-level `ChatSession` API which wraps the
/// `UserInput` → token-iteration → string-output pipeline. We single-turn
/// each request (no chat history retention) because translation prompts
/// are independent.
actor TranslationEngine: TranslationEngineProtocol {
    private var state: TranslationEngineState = .unloaded
    private var container: ModelContainer?

    /// Cap the raw input to keep latency bounded. The prompt template
    /// adds a small fixed overhead on top of this.
    private static let maxInputChars = 2000

    var stateSnapshot: TranslationEngineState { state }

    init() {}

    func load(modelDir: URL) async throws {
        switch state {
        case .ready, .loading:
            return
        case .unloaded, .failed:
            break
        }
        state = .loading
        do {
            // MLX 2.29.1: a `ModelConfiguration` carrying a `.directory`
            // identifier tells `downloadModel` to use the directory
            // as-is, so no network traffic occurs here.
            let configuration = ModelConfiguration(directory: modelDir)
            container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            )
            state = .ready
        } catch {
            container = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func translate(_ text: String,
                   from source: String,
                   to target: String) async throws -> String {
        guard case .ready = state, let container else {
            throw TranslationError.notReady
        }
        let truncated = Self.truncate(text, max: Self.maxInputChars)
        let prompt = Self.buildPrompt(text: truncated,
                                      source: source,
                                      target: target)

        // GenerateParameters: low temperature for determinism, modest
        // max-tokens to bound runtime on long inputs.
        let parameters = GenerateParameters(maxTokens: 800,
                                            temperature: 0.2)
        let session = ChatSession(container,
                                  generateParameters: parameters)
        let raw = try await session.respond(to: prompt)
        return Self.cleanOutput(raw)
    }

    // MARK: - Helpers (internal for testability)

    static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "\u{2026}"
    }

    static func buildPrompt(text: String,
                            source: String,
                            target: String) -> String {
        let srcName = Locale.current.localizedString(forLanguageCode: source)
            ?? source
        let tgtName = Locale.current.localizedString(forLanguageCode: target)
            ?? target
        return """
        Translate the following \(srcName) text to \(tgtName).
        Output ONLY the translation, no commentary, no quotes, no prefixes.

        \(text)
        """
    }

    static func cleanOutput(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("\u{00AB}", "\u{00BB}"),
            ("\u{201C}", "\u{201D}"),
        ]
        for (open, close) in quotePairs {
            if out.count >= 2, out.first == open, out.last == close {
                out = String(out.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return out
    }
}
