import Foundation
import Observation
import SwiftUI

@Observable @MainActor
final class TranslationViewModel {
    /// MLX engine call signatures. `TranslationEngine` provides both in
    /// production; tests pass inline closures that record arguments and
    /// return canned results.
    typealias LoadEngine = @Sendable (URL) async throws -> Void
    typealias TranslateText = @Sendable (String, String, String) async throws -> String

    let store: TranslationStore
    let model: TranslationModelManager
    let loadEngine: LoadEngine
    let translateText: TranslateText

    /// Backing storage for AppStorage. The actual `@AppStorage` wrapper
    /// lives in views — we expose them as plain properties here so the
    /// VM can be unit-tested against UserDefaults directly.
    var targetLang: String {
        get { UserDefaults.standard.string(
            forKey: "yawac.translate.targetLang") ?? "en" }
        set { UserDefaults.standard.set(
            newValue, forKey: "yawac.translate.targetLang") }
    }
    private(set) var denylist: Set<String> = []

    init(store: TranslationStore,
         model: TranslationModelManager,
         loadEngine: @escaping LoadEngine,
         translateText: @escaping TranslateText) {
        self.store = store
        self.model = model
        self.loadEngine = loadEngine
        self.translateText = translateText
        refreshFromDefaults()
    }

    /// Re-reads `denylist` from UserDefaults. Called on init and when
    /// tests mutate UserDefaults directly.
    func refreshFromDefaults() {
        let json = UserDefaults.standard.string(
            forKey: "yawac.translate.denyJSON") ?? "[]"
        let arr = (try? JSONDecoder().decode(
            [String].self, from: Data(json.utf8))) ?? []
        denylist = Set(arr)
    }

    private func persistDenylist() {
        let arr = denylist.sorted()
        if let data = try? JSONEncoder().encode(arr),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json,
                                      forKey: "yawac.translate.denyJSON")
        }
    }

    /// Whether the chat row should render a Translate link, plus the
    /// detected language.
    func shouldOfferTranslate(text: String) -> (offer: Bool, lang: String?) {
        guard let lang = LanguageDetector.detect(text) else {
            return (false, nil)
        }
        if lang == targetLang { return (false, lang) }
        if denylist.contains(lang) { return (false, lang) }
        return (true, lang)
    }

    func translate(surfaceID: String,
                   text: String,
                   source: String) async {
        guard case .ready(let modelDir) = model.state else { return }

        if store.entry(for: surfaceID) != nil {
            store.toggle(surfaceID)
            return
        }
        guard store.startInFlight(surfaceID) else { return }
        // Engine load is idempotent — if it's already .ready or .loading,
        // this returns fast. Covers the cold-download case where the
        // model arrived after app launch and the AppRoot preload never
        // ran.
        do {
            try await loadEngine(modelDir)
        } catch {
            NSLog("[yawac/translate] engine load failed: %@", "\(error)")
            store.fail(surfaceID)
            return
        }
        do {
            let translated = try await translateText(
                text, source, targetLang)
            store.finish(surfaceID, with: TranslationStore.Entry(
                original: text,
                translated: translated,
                sourceLang: source,
                showingTranslated: true))
        } catch {
            NSLog("[yawac/translate] failed: %@", "\(error)")
            store.fail(surfaceID)
        }
    }

    func toggle(surfaceID: String) {
        store.toggle(surfaceID)
    }

    func denyLanguage(_ code: String) {
        denylist.insert(code)
        persistDenylist()
    }

    func allowLanguage(_ code: String) {
        denylist.remove(code)
        persistDenylist()
    }
}
