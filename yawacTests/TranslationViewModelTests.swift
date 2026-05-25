import XCTest
@testable import yawac

@MainActor
final class TranslationViewModelTests: XCTestCase {

    // MARK: Fakes

    actor FakeEngine: TranslationEngineProtocol {
        var loadCalls: [URL] = []
        var translateCalls: [(text: String, source: String, target: String)] = []
        var nextResult: Result<String, Error> = .success("HELLO")
        var _state: TranslationEngineState = .ready

        var stateSnapshot: TranslationEngineState { _state }

        func load(modelDir: URL) async throws {
            loadCalls.append(modelDir)
        }
        func translate(_ text: String,
                       from source: String,
                       to target: String) async throws -> String {
            translateCalls.append((text, source, target))
            switch nextResult {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
        func setNext(_ r: Result<String, Error>) { nextResult = r }
        func setState(_ s: TranslationEngineState) { _state = s }
    }

    private func makeVM(
        engine: TranslationEngineProtocol = FakeEngine(),
        modelReady: Bool = true,
        target: String = "en",
        denylist: Set<String> = []
    ) -> TranslationViewModel {
        let store = TranslationStore()
        let mgr = TranslationModelManager(
            rootOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("yawac-test-\(UUID().uuidString)"))
        if modelReady {
            let dir = mgr.localDir
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(
                to: dir.appendingPathComponent("config.json"))
            try? Data("{}".utf8).write(
                to: dir.appendingPathComponent("tokenizer.json"))
            try? Data([0]).write(
                to: dir.appendingPathComponent("model.safetensors"))
            mgr.refreshState()
        }
        UserDefaults.standard.set(target, forKey: "yawac.translate.targetLang")
        let arr = denylist.sorted()
        let json = (try? String(
            data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[]"
        UserDefaults.standard.set(json, forKey: "yawac.translate.denyJSON")
        let vm = TranslationViewModel(
            store: store, model: mgr, engine: engine)
        vm.refreshFromDefaults()
        return vm
    }

    // MARK: Tests

    func testShouldOfferReturnsFalseWhenTargetEqualsDetected() {
        let vm = makeVM(target: "de")
        let r = vm.shouldOfferTranslate(
            text: "Das ist ein ganz normaler Satz auf Deutsch.")
        XCTAssertFalse(r.offer)
        XCTAssertEqual(r.lang, "de")
    }

    func testShouldOfferReturnsFalseWhenLangInDenylist() {
        let vm = makeVM(target: "en", denylist: ["de"])
        let r = vm.shouldOfferTranslate(
            text: "Das ist ein ganz normaler Satz auf Deutsch.")
        XCTAssertFalse(r.offer)
    }

    func testShouldOfferReturnsTrueOtherwise() {
        let vm = makeVM(target: "en")
        let r = vm.shouldOfferTranslate(
            text: "Das ist ein ganz normaler Satz auf Deutsch.")
        XCTAssertTrue(r.offer)
        XCTAssertEqual(r.lang, "de")
    }

    func testDenyLanguagePersistsAndAffectsShouldOffer() {
        let vm = makeVM(target: "en")
        vm.denyLanguage("de")
        let r = vm.shouldOfferTranslate(
            text: "Das ist ein ganz normaler Satz auf Deutsch.")
        XCTAssertFalse(r.offer)
        XCTAssertTrue(vm.denylist.contains("de"))
    }

    func testTranslateShortCircuitsOnModelAbsent() async {
        let engine = FakeEngine()
        let vm = makeVM(engine: engine, modelReady: false)
        await vm.translate(surfaceID: "msg1:text",
                           text: "Hallo Welt schöner Tag heute",
                           source: "de")
        let calls = await engine.translateCalls
        XCTAssertTrue(calls.isEmpty,
                      "engine must not be called when model is absent")
        XCTAssertNil(vm.store.entry(for: "msg1:text"))
    }

    func testTranslateStoresEntryOnSuccess() async {
        let engine = FakeEngine()
        await engine.setNext(.success("Hello world nice day today"))
        let vm = makeVM(engine: engine)
        await vm.translate(surfaceID: "msg1:text",
                           text: "Hallo Welt schöner Tag heute",
                           source: "de")
        let entry = vm.store.entry(for: "msg1:text")
        XCTAssertEqual(entry?.translated, "Hello world nice day today")
        XCTAssertEqual(entry?.sourceLang, "de")
        XCTAssertEqual(entry?.showingTranslated, true)
    }

    func testTranslateMarksFailOnError() async {
        struct Boom: Error {}
        let engine = FakeEngine()
        await engine.setNext(.failure(Boom()))
        let vm = makeVM(engine: engine)
        await vm.translate(surfaceID: "msg1:text",
                           text: "Hallo Welt schöner Tag heute",
                           source: "de")
        XCTAssertNil(vm.store.entry(for: "msg1:text"))
    }

    func testTranslateDoesNotReenterWhileInFlight() async {
        actor SlowEngine: TranslationEngineProtocol {
            var stateSnapshot: TranslationEngineState = .ready
            var calls = 0
            var continuation: CheckedContinuation<String, Error>?
            func load(modelDir: URL) async throws {}
            func translate(_ text: String,
                           from s: String,
                           to t: String) async throws -> String {
                calls += 1
                return try await withCheckedThrowingContinuation { c in
                    continuation = c
                }
            }
            func release(_ value: String) {
                continuation?.resume(returning: value)
                continuation = nil
            }
            var callCount: Int { calls }
        }
        let engine = SlowEngine()
        let vm = makeVM(engine: engine)
        async let first: Void = vm.translate(
            surfaceID: "msg1:text",
            text: "Hallo Welt schöner Tag heute",
            source: "de")
        try? await Task.sleep(for: .milliseconds(20))
        await vm.translate(surfaceID: "msg1:text",
                           text: "Hallo Welt schöner Tag heute",
                           source: "de")
        await engine.release("done")
        await first
        let n = await engine.callCount
        XCTAssertEqual(n, 1, "second call must short-circuit")
    }
}
