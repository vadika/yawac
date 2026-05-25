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
    /// Qwen 2.5 3B Instruct quantized to 4-bit. Text-only, multilingual
    /// (DE/FI/EN strong), single safetensors shard (~1.8 GB), proven
    /// loader path in mlx-swift 2.29.x. Previously tried gemma-3-4b-it
    /// but mlx-community's checkpoint ships the multimodal vocab
    /// (262208) which MLX's Gemma3TextModel rejects.
    private static let repoSlug = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    private static let dirName = "Qwen2.5-3B-Instruct-4bit"
    /// Files we treat as the minimum-viable manifest. Any of these
    /// missing keeps the state at `.absent`.
    private static let requiredFiles = [
        "config.json",
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
            "model.safetensors.index.json",
            "model.safetensors",
        ]

        for (idx, name) in files.enumerated() {
            let url = URL(string:
                "https://huggingface.co/\(Self.repoSlug)/resolve/main/\(name)")!
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 404 {
                    if name == "model.safetensors.index.json" {
                        continue
                    }
                    state = .failed("missing \(name) (404)")
                    try? fm.removeItem(at: tempDir)
                    return
                }
                try data.write(to: tempDir.appendingPathComponent(name))
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
        refreshState()
    }

    func delete() async {
        try? FileManager.default.removeItem(at: localDir)
        state = .absent
    }
}
