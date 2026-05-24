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
        try? await Task.sleep(for: .milliseconds(10))
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
        try? await Task.sleep(for: .milliseconds(10))
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
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(search.filteredChats.isEmpty)
    }
}

@MainActor
enum ChatListViewModelTestHarness {
    static func make() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }
}
