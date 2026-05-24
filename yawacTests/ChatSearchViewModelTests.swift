import XCTest
@testable import yawac

@MainActor
final class ChatSearchViewModelTests: XCTestCase {

    // MARK: - Test fixtures

    final class FakeValidator: PhoneValidating {
        var ownJID: String = ""
        var stub: Result<PhoneCheckResult, Error> = .success(
            PhoneCheckResult(jid: "", registered: false, businessName: nil))
        var calls: [String] = []

        func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
            calls.append(phone)
            switch stub {
            case .success(let r): return r
            case .failure(let e): throw e
            }
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
        try? await Task.sleep(for: .milliseconds(50))
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
        try? await Task.sleep(for: .milliseconds(50))
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
        try? await Task.sleep(for: .milliseconds(50))
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
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456789@s.whatsapp.net",
            registered: true, businessName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+49 151 2345 6789"
        try? await Task.sleep(for: .milliseconds(50))
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
            registered: true, businessName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4915123456789"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(search.suggestion)
    }

    func testValidationClearsSuggestionWhenNotRegistered() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.stub = .success(PhoneCheckResult(jid: "", registered: false, businessName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 1
        search.query = "+4915999999999"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(search.suggestion)
    }

    func testValidationDebouncesRapidQueryChanges() async {
        let list = makeListVM(chats: [])
        let v = FakeValidator()
        v.stub = .success(PhoneCheckResult(
            jid: "4915123456788@s.whatsapp.net",
            registered: true, businessName: nil))
        let search = ChatSearchViewModel(listVM: list, validator: v)
        search.debounceMs = 20
        search.query = "+491512345678"
        search.query = "+4915123456788"
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(v.calls.count, 1)
        XCTAssertEqual(v.calls.first, "4915123456788")
    }
}

@MainActor
enum ChatListViewModelTestHarness {
    static func make() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }
}
