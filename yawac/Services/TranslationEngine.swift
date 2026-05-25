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
        let instructions = Self.buildInstructions(source: source,
                                                  target: target)

        // GenerateParameters: low temperature for determinism, modest
        // max-tokens to bound runtime on long inputs.
        let parameters = GenerateParameters(maxTokens: 800,
                                            temperature: 0.2)
        let session = ChatSession(container,
                                  instructions: instructions,
                                  generateParameters: parameters)
        // User message is JUST the source text. Role/format constraints
        // live in `instructions` (the system prompt), which Qwen 2.5
        // respects far more reliably than prefacing the user turn.
        let raw = try await session.respond(to: truncated)
        return Self.cleanOutput(raw, target: target)
    }

    // MARK: - Helpers (internal for testability)

    static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "\u{2026}"
    }

    static func buildInstructions(source: String, target: String) -> String {
        let srcName = Locale.current.localizedString(forLanguageCode: source)
            ?? source
        let tgtName = Locale.current.localizedString(forLanguageCode: target)
            ?? target
        return """
        You are a translation engine. The user message contains \(srcName) \
        text. Translate it into \(tgtName) and output ONLY the translation.

        Rules:
        - Do NOT include any prefix such as "Translation:", \
          "\(tgtName):", "Here is the translation:", or similar.
        - Do NOT wrap the output in quotes, backticks, or asterisks.
        - Do NOT add commentary, notes, or explanations.
        - Do NOT repeat the source text.
        - Preserve URLs, @mentions, emoji, and line breaks verbatim.
        - If the input is already in \(tgtName), return it unchanged.
        """
    }

    /// Strip common artefacts Qwen 2.5 occasionally adds despite the
    /// system prompt: leading "Translation:" / "<TargetLang>:" labels,
    /// surrounding markdown/quote wrappers, and a final stray label
    /// when the model echoes the source first.
    static func cleanOutput(_ s: String, target: String = "") -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip a markdown bold/italic wrapper around the whole reply.
        if out.hasPrefix("**"), out.hasSuffix("**"), out.count >= 4 {
            out = String(out.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Strip surrounding quote pairs.
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

        // 3. Strip leading label prefixes the model sometimes prepends.
        out = stripLeadingLabel(out, target: target)

        return out
    }

    private static let labelPrefixes: [String] = [
        "translation:",
        "translated text:",
        "translated:",
        "here is the translation:",
        "here's the translation:",
        "here is the translated text:",
        "output:",
        "result:",
    ]

    private static func stripLeadingLabel(_ s: String, target: String) -> String {
        let lower = s.lowercased()
        for prefix in labelPrefixes {
            if lower.hasPrefix(prefix) {
                return String(s.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Target-language label, e.g. "English:" or "Deutsch:".
        if !target.isEmpty,
           let tgtName = Locale.current.localizedString(forLanguageCode: target) {
            for variant in [tgtName, target] {
                let label = "\(variant.lowercased()):"
                if lower.hasPrefix(label) {
                    return String(s.dropFirst(label.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return s
    }
}
