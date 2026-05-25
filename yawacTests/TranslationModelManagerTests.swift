import XCTest
@testable import yawac

@MainActor
final class TranslationModelManagerTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    func testStateIsAbsentWhenDirMissing() {
        let mgr = TranslationModelManager(rootOverride: tempDir())
        mgr.refreshState()
        if case .absent = mgr.state {
            // pass
        } else {
            XCTFail("expected .absent, got \(mgr.state)")
        }
    }

    func testStateIsReadyWhenManifestAndShardsPresent() throws {
        let root = tempDir()
        let modelDir = root.appendingPathComponent(
            "models/Qwen2.5-3B-Instruct-4bit", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: modelDir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(
            to: modelDir.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(
            to: modelDir.appendingPathComponent("tokenizer_config.json"))
        try Data([0]).write(
            to: modelDir.appendingPathComponent("model.safetensors"))

        let mgr = TranslationModelManager(rootOverride: root)
        mgr.refreshState()
        if case .ready(let url) = mgr.state {
            XCTAssertEqual(url, modelDir)
        } else {
            XCTFail("expected .ready, got \(mgr.state)")
        }
    }

    func testDeleteRemovesDirAndFlipsState() async throws {
        let root = tempDir()
        let modelDir = root.appendingPathComponent(
            "models/Qwen2.5-3B-Instruct-4bit", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: modelDir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(
            to: modelDir.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(
            to: modelDir.appendingPathComponent("tokenizer_config.json"))
        try Data([0]).write(
            to: modelDir.appendingPathComponent("model.safetensors"))

        let mgr = TranslationModelManager(rootOverride: root)
        mgr.refreshState()
        await mgr.delete()
        if case .absent = mgr.state {
            // pass
        } else {
            XCTFail("expected .absent after delete, got \(mgr.state)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: modelDir.path))
    }
}
