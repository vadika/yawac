import XCTest
@testable import yawac

@MainActor
final class ChatSearchViewModelTests: XCTestCase {

    // MARK: - Test fixtures

    final class FakeValidator: PhoneValidating {
        var ownJID: String = ""
        var stub: Result<PhoneCheckResult, Error> = .success(
            PhoneCheckResult(jid: "", registered: false, businessName: nil, pushName: nil, fullName: nil))
        var calls: [String] = []

        func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
            calls.append(phone)
            switch stub {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    /// Poll up to ~2s instead of fixed sleeps — the debounce pipeline's
    /// timing flakes under machine load (recurring suite failure family).
    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeListVM(chats: [Chat] = []) -> ChatListViewModel {
        let vm = ChatListViewModelTestHarness.make()
        vm.chats = chats
        return vm
    }

    private func makeChat(jid: String, name: String) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "", lastTimestamp: 0, unread: 0)
    }

    // MARK: - Tests

    func testEmptyQueryPassesThroughAllChats() {
        let list = makeListVM(chats: [
            makeChat(jid: "1@s.whatsapp.net", name: "Alice"),
            makeChat(jid: "2@s.whatsapp.net", name: "Bob"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        XCTAssertEqual(search.filteredChats.count, 2)
        XCTAssertNil(search.suggestion)
    }

    func testSettingThenClearingQueryRestoresAllChats() async {
        let list = makeListVM(chats: [
            makeChat(jid: "1@s.whatsapp.net", name: "Alice"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        search.debounceMs = 1
        search.query = "x"
        try? await Task.sleep(for: .milliseconds(10))
        search.query = ""
        XCTAssertEqual(search.filteredChats.count, 1)
        XCTAssertNil(search.suggestion)
    }

    func testFiltersByCaseInsensitiveNameSubstring() async {
        let list = makeListVM(chats: [
            makeChat(jid: "1@s.whatsapp.net", name: "Alice Smith"),
            makeChat(jid: "2@s.whatsapp.net", name: "Bob Jones"),
            makeChat(jid: "3@s.whatsapp.net", name: "Carol Smith"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        search.debounceMs = 1
        search.query = "smith"
        await waitUntil { search.filteredChats.count == 2 }
        XCTAssertEqual(Set(search.filteredChats.map(\.jid)),
                       Set(["1@s.whatsapp.net", "3@s.whatsapp.net"]))
    }

    func testFiltersByDigitSubstringAcrossJIDFormats() async {
        let list = makeListVM(chats: [
            makeChat(jid: "4915123456789@s.whatsapp.net", name: "Alice"),
            makeChat(jid: "4915999999999@s.whatsapp.net", name: "Bob"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        search.debounceMs = 1
        search.query = "+49 151 2345"
        await waitUntil { search.filteredChats.count == 1 }
        XCTAssertEqual(search.filteredChats.map(\.jid),
                       ["4915123456789@s.whatsapp.net"])
    }

    func testFilterReturnsEmptyOnNoMatch() async {
        let list = makeListVM(chats: [
            makeChat(jid: "1@s.whatsapp.net", name: "Alice"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        search.debounceMs = 1
        search.query = "zzzz"
        await waitUntil { search.filteredChats.isEmpty }
        XCTAssertTrue(search.filteredChats.isEmpty)
    }

    // MARK: - Phone heuristic tests

    func testPhoneHeuristicAcceptsPlusForm() {
        XCTAssertTrue(ChatSearchViewModel.looksLikePhone("+491"))
        XCTAssertTrue(ChatSearchViewModel.looksLikePhone("+49 151 234 56 78"))
    }

    func testPhoneHeuristicAcceptsSevenPlusDigits() {
        XCTAssertTrue(ChatSearchViewModel.looksLikePhone("1234567"))
        XCTAssertTrue(ChatSearchViewModel.looksLikePhone("4915123456789"))
    }

    func testPhoneHeuristicRejectsShortDigits() {
        XCTAssertFalse(ChatSearchViewModel.looksLikePhone("12345"))
    }

    func testPhoneHeuristicRejectsLetters() {
        XCTAssertFalse(ChatSearchViewModel.looksLikePhone("hello"))
        XCTAssertFalse(ChatSearchViewModel.looksLikePhone("alice123"))
    }

    // MARK: - Bridge validation tests

    func testValidationFiresForUnknownPhone() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456789@s.whatsapp.net",
            registered: true, businessName: nil, pushName: nil, fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+49 151 2345 6789"
        await waitUntil { search.suggestion != nil }
        XCTAssertEqual(v.calls, ["4915123456789"])
        XCTAssertEqual(search.suggestion?.jid, "4915123456789@s.whatsapp.net")
    }

    func testValidationSkippedWhenChatAlreadyMatches() async {
        let list = makeListVM(chats: [
            makeChat(jid: "4915123456789@s.whatsapp.net", name: "Alice"),
        ])
        let v = FakeValidator()
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+49 151 2345 6789"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(v.calls.isEmpty)
        XCTAssertNil(search.suggestion)
    }

    func testValidationDoesNotFireForNonPhoneQuery() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "hello"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(v.calls.isEmpty)
    }

    func testValidationSuppressesSelfJID() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "4915123456789@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456789@s.whatsapp.net",
            registered: true, businessName: nil, pushName: nil, fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4915123456789"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(search.suggestion)
    }

    func testValidationClearsSuggestionWhenNotRegistered() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(jid: "", registered: false, businessName: nil, pushName: nil, fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4915999999999"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(search.suggestion)
    }

    func testValidationDebouncesRapidQueryChanges() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456788@s.whatsapp.net",
            registered: true, businessName: nil, pushName: nil, fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 20
        search.query = "+491512345678"
        search.query = "+4915123456788"
        await waitUntil { !v.calls.isEmpty }
        XCTAssertEqual(v.calls.count, 1)
        XCTAssertEqual(v.calls.first, "4915123456788")
    }

    func testValidationSkippedWhenLoggedOut() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = ""  // not paired
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4915123456789"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(v.calls.isEmpty, "should not call bridge when logged out")
        XCTAssertNil(search.suggestion)
        XCTAssertFalse(search.validating)
    }

    func testRateLimitedPreservesPriorSuggestion() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        // First query — successful suggestion.
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456789@s.whatsapp.net",
            registered: true, businessName: nil, pushName: nil, fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4915123456789"
        // Poll instead of fixed sleeps — 50ms budgets flake under load.
        for _ in 0..<100 where search.suggestion == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(search.suggestion)
        // Second query — bridge rate-limits.
        v.stub = .failure(NSError(domain: "Bridge", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "rate_limited"]))
        search.query = "+4915999999999"
        for _ in 0..<100 where v.calls.count < 2 || search.validating {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Prior suggestion preserved.
        XCTAssertEqual(search.suggestion?.jid, "4915123456789@s.whatsapp.net")
        XCTAssertFalse(search.validating)
    }

    func testValidatingClearsOnCancellation() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456789@s.whatsapp.net",
            registered: true, businessName: nil, pushName: nil, fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 50
        search.query = "+4915123456789"
        // Immediately cancel via a new query before debounce fires.
        try? await Task.sleep(for: .milliseconds(5))
        search.query = ""
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(search.validating, "validating must clear after cancellation")
    }

    // MARK: - Best-name selection tests

    func testSuggestionPrefersBusinessNameOverPhone() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4912345@s.whatsapp.net",
            registered: true,
            businessName: "Acme",
            pushName: nil,
            fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4912345678"
        await waitUntil { search.suggestion != nil }
        XCTAssertEqual(search.suggestion?.displayPhone, "Acme")
    }

    func testSuggestionFallsBackToPushName() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4912345@s.whatsapp.net",
            registered: true,
            businessName: nil,
            pushName: "Bob",
            fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4912345678"
        await waitUntil { search.suggestion != nil }
        XCTAssertEqual(search.suggestion?.displayPhone, "Bob")
    }

    func testSuggestionFallsBackToFullName() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4912345@s.whatsapp.net",
            registered: true,
            businessName: nil,
            pushName: nil,
            fullName: "Carol Jones"))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4912345678"
        await waitUntil { search.suggestion != nil }
        XCTAssertEqual(search.suggestion?.displayPhone, "Carol Jones")
    }

    func testSuggestionFallsBackToPhoneWhenNoName() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.ownJID = "self@s.whatsapp.net"
        v.stub = .success(PhoneCheckResult(
            jid: "4912345678@s.whatsapp.net",
            registered: true,
            businessName: nil,
            pushName: nil,
            fullName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4912345678"
        await waitUntil { search.suggestion != nil }
        XCTAssertEqual(search.suggestion?.displayPhone, "+4912345678")
    }

    // MARK: - upsertStubChat tests

    func testUpsertStubChatAddsNewRow() {
        let vm = ChatListViewModelTestHarness.make()
        let id = vm.upsertStubChat(jid: "499@s.whatsapp.net", displayName: "+499")
        XCTAssertEqual(id, "499@s.whatsapp.net")
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertEqual(vm.chats.first?.jid, "499@s.whatsapp.net")
        XCTAssertEqual(vm.chats.first?.name, "+499")
    }

    func testUpsertStubChatIsIdempotent() {
        let vm = ChatListViewModelTestHarness.make()
        let existing = Chat(
            jid: "499@s.whatsapp.net", name: "Alice",
            lastMessage: "hi", lastTimestamp: 100, unread: 0)
        vm.chats = [existing]
        let id = vm.upsertStubChat(jid: "499@s.whatsapp.net", displayName: "+499")
        XCTAssertEqual(id, "499@s.whatsapp.net")
        XCTAssertEqual(vm.chats.count, 1)
        XCTAssertEqual(vm.chats.first?.name, "Alice", "should NOT overwrite real name")
        XCTAssertEqual(vm.chats.first?.lastMessage, "hi")
    }

    func testGlobalMessageSearchPopulatesHits() async throws {
        // Warm up the structured-concurrency timer subsystem (cold-start
        // ~400ms on this hardware otherwise swamps the debounce window).
        try await Task.sleep(for: .milliseconds(1))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-sbs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let idx = MessageIndex(storeURL: tmp)
        idx.ensureSchema()
        idx.upsert(.init(messageID: "m1", chatJID: "A@s.whatsapp.net",
                         timestamp: 10, kind: "text",
                         text: "Hello Finland",
                         caption: "", quoted: "", sender: "Alice",
                         fromMe: false, senderJID: ""))
        idx.upsert(.init(messageID: "m2", chatJID: "B@s.whatsapp.net",
                         timestamp: 20, kind: "text",
                         text: "Goodbye Finland",
                         caption: "", quoted: "", sender: "Bob",
                         fromMe: false, senderJID: ""))

        let list = makeListVM(chats: [])
        let vm = ChatSearchViewModel(listVM: list,
                                     validator: FakeValidator(),
                                     messageIndex: idx)
        vm.debounceMs = 20
        vm.query = "finland"
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(vm.messageHits.count, 2)
    }

    func testGlobalSearchCancellation() async throws {
        try await Task.sleep(for: .milliseconds(1))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yawac-sbs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let idx = MessageIndex(storeURL: tmp)
        idx.ensureSchema()
        idx.upsert(.init(messageID: "m1", chatJID: "A@s.whatsapp.net",
                         timestamp: 10, kind: "text",
                         text: "Finland",
                         caption: "", quoted: "", sender: "",
                         fromMe: false, senderJID: ""))
        idx.upsert(.init(messageID: "m2", chatJID: "A@s.whatsapp.net",
                         timestamp: 20, kind: "text",
                         text: "Sweden",
                         caption: "", quoted: "", sender: "",
                         fromMe: false, senderJID: ""))

        let list = makeListVM(chats: [])
        let vm = ChatSearchViewModel(listVM: list,
                                     validator: FakeValidator(),
                                     messageIndex: idx)
        vm.debounceMs = 20
        vm.query = "fin"
        vm.query = "swe"
        // Poll instead of a fixed sleep — the 200ms budget flaked under
        // machine load (this suite's known debounce-race family).
        for _ in 0..<50 where vm.messageHits.map(\.messageID) != ["m2"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(vm.messageHits.map(\.messageID), ["m2"])
    }
}

@MainActor
enum ChatListViewModelTestHarness {
    static func make() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }
}
