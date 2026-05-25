import XCTest
@testable import yawac

final class TranslationEngineTests: XCTestCase {
    func testTranslateGermanToEnglish() async throws {
        guard ProcessInfo.processInfo
            .environment["YAWAC_RUN_ML_TESTS"] == "1" else {
            throw XCTSkip("set YAWAC_RUN_ML_TESTS=1 to run")
        }
        let mgr = await TranslationModelManager()
        await MainActor.run { mgr.refreshState() }
        let modelURL: URL
        switch await MainActor.run(body: { mgr.state }) {
        case .ready(let url):
            modelURL = url
        default:
            throw XCTSkip("model not present; download via Settings first")
        }

        let engine = TranslationEngine()
        try await engine.load(modelDir: modelURL)
        let out = try await engine.translate(
            "Hallo Welt, wie geht es dir?",
            from: "de", to: "en")
        let lower = out.lowercased()
        XCTAssertTrue(lower.contains("hello"), "got: \(out)")
        XCTAssertTrue(
            lower.contains("world") || lower.contains("how are"),
            "got: \(out)")
    }
}
