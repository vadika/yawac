import Foundation
import Observation

/// Manages on-disk presence of the MLX translation model. Owns the
/// download lifecycle (atomic temp → final move, resume via ETag) and
/// exposes `state` for Settings to render progress / status.
@Observable @MainActor
final class TranslationModelManager {
    enum State: Equatable {
        case absent
        case downloading(progress: Double)
        case ready(URL)
        case failed(String)
    }

    private(set) var state: State = .absent

    private let root: URL
    /// Google's translation-specialized Gemma 3 4B checkpoint, quantized
    /// to 4-bit for on-device inference with MLX (~2.2 GB).
    private static let repoSlug = "mlx-community/translategemma-4b-it-4bit"
    private static let dirName = "translategemma-4b-it-4bit"
    private static let legacyDirName = "Qwen2.5-3B-Instruct-4bit"
    /// Files we treat as the minimum-viable manifest. Any of these
    /// missing keeps the state at `.absent`.
    private static let requiredFiles = [
        "config.json",
        "chat_template.jinja",
        "tokenizer.json",
        "tokenizer_config.json",
    ]
    /// At least one weight shard with this prefix must exist.
    private static let weightPrefix = "model"
    private static let weightSuffix = ".safetensors"

    /// Production initializer pins `root` to Application Support.
    /// `rootOverride` is for tests.
    init(rootOverride: URL? = nil) {
        if let rootOverride {
            self.root = rootOverride
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.root = appSupport.appendingPathComponent("yawac",
                                                          isDirectory: true)
        }
    }

    var localDir: URL {
        root.appendingPathComponent("models/\(Self.dirName)",
                                    isDirectory: true)
    }

    private var legacyDir: URL {
        root.appendingPathComponent("models/\(Self.legacyDirName)",
                                    isDirectory: true)
    }

    /// Inspects the local dir and updates `state`. Synchronous, cheap.
    func refreshState() {
        let dir = localDir
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            state = .absent
            return
        }
        for name in Self.requiredFiles {
            let path = dir.appendingPathComponent(name).path
            if !fm.fileExists(atPath: path) {
                state = .absent
                return
            }
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasWeights = contents.contains { name in
            name.hasPrefix(Self.weightPrefix) &&
                name.hasSuffix(Self.weightSuffix)
        }
        guard hasWeights else {
            state = .absent
            return
        }
        state = .ready(dir)
    }

    /// Streams the model from HuggingFace into a temp dir, then renames
    /// into place. Updates `state` continuously. Best-effort; failures
    /// surface as `.failed(msg)`.
    func download() async {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root,
                                   withIntermediateDirectories: true)
        } catch {
            state = .failed("create root: \(error.localizedDescription)")
            return
        }
        let tempDir = root.appendingPathComponent(
            "models/\(Self.dirName).tmp", isDirectory: true)
        try? fm.removeItem(at: tempDir)
        do {
            try fm.createDirectory(at: tempDir,
                                   withIntermediateDirectories: true)
        } catch {
            state = .failed("create temp: \(error.localizedDescription)")
            return
        }

        state = .downloading(progress: 0)
        let files = Self.requiredFiles + [
            "added_tokens.json",
            "generation_config.json",
            "model.safetensors.index.json",
            "model.safetensors",
            "special_tokens_map.json",
            "tokenizer.model",
        ]

        for (idx, name) in files.enumerated() {
            let url = URL(string:
                "https://huggingface.co/\(Self.repoSlug)/resolve/main/\(name)")!
            do {
                // A download task writes to a temporary file instead of
                // retaining the multi-gigabyte weight shard in memory.
                let (downloaded, response) = try await URLSession.shared
                    .download(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(http.statusCode) {
                    state = .failed("\(name): HTTP \(http.statusCode)")
                    try? fm.removeItem(at: tempDir)
                    return
                }
                try fm.moveItem(
                    at: downloaded,
                    to: tempDir.appendingPathComponent(name))
                state = .downloading(
                    progress: Double(idx + 1) / Double(files.count))
            } catch {
                state = .failed("\(name): \(error.localizedDescription)")
                try? fm.removeItem(at: tempDir)
                return
            }
        }

        let finalDir = localDir
        try? fm.removeItem(at: finalDir)
        do {
            try fm.moveItem(at: tempDir, to: finalDir)
        } catch {
            state = .failed("rename: \(error.localizedDescription)")
            return
        }
        // Keep the previous model until the replacement is complete, then
        // reclaim its disk space.
        try? fm.removeItem(at: legacyDir)
        refreshState()
    }

    func delete() async {
        try? FileManager.default.removeItem(at: localDir)
        try? FileManager.default.removeItem(at: legacyDir)
        state = .absent
    }
}
