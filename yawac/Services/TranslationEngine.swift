import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Lifecycle state of a `TranslationEngine`.
enum TranslationEngineState: Equatable {
    case unloaded
    case loading
    case ready
    case failed(String)
}

enum TranslationError: Error {
    case notReady
}

/// Concrete MLX-backed engine.
///
/// Loading uses a directory-backed configuration, so inference never
/// reaches the Hub. TranslateGemma requires structured source and target
/// language metadata; the upstream message generator turns that metadata
/// into the model's specialized chat template.
actor TranslationEngine {
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
            let configuration = ModelConfiguration(
                directory: modelDir,
                extraEOSTokens: ["<end_of_turn>"],
                messageGenerator: TranslateGemma3MessageGenerator()
            )
            let resolved = configuration.resolved(
                modelDirectory: modelDir,
                tokenizerDirectory: modelDir
            )
            let modelContext = try await LLMModelFactory.shared._load(
                configuration: resolved,
                tokenizerLoader: TransformersTokenizerLoader()
            )
            container = ModelContainer(context: modelContext)
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
        let context = Self.translationContext(source: source, target: target)
        let userInput = UserInput(
            prompt: truncated,
            additionalContext: context
        )
        let parameters = GenerateParameters(maxTokens: 800,
                                            temperature: 0)

        let raw = try await container.perform(
            nonSendable: userInput
        ) { modelContext, userInput in
            let input = try await modelContext.processor.prepare(
                input: userInput)
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: modelContext
            )
            var output = ""
            for await generation in stream {
                if let chunk = generation.chunk {
                    output += chunk
                }
            }
            return output
        }
        return Self.cleanOutput(raw, target: target)
    }

    // MARK: - Helpers (internal for testability)

    static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "\u{2026}"
    }

    static func translationContext(source: String,
                                   target: String) -> [String: String] {
        [
            "source_lang_code": source.replacingOccurrences(of: "_", with: "-"),
            "target_lang_code": target.replacingOccurrences(of: "_", with: "-"),
        ]
    }

    /// Strip common model artefacts: leading "Translation:" /
    /// "<TargetLang>:" labels,
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

/// Bridges swift-transformers to the provider-neutral tokenizer API used
/// by mlx-swift-lm 3.x. Kept local because model downloads remain owned by
/// `TranslationModelManager` rather than the Hugging Face cache.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(
            modelFolder: directory)
        return TransformersTokenizer(upstream: tokenizer)
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds,
                        skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
