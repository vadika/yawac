import XCTest
import SwiftData
@testable import yawac

@MainActor
final class ChatListViewModelFolderRefreshTests: XCTestCase {

    func testRefreshFolderIDsForSingleJID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Seed PersistedChat with folderIDs set.
        let row = PersistedChat(jid: "111@s.whatsapp.net", name: "Alice")
        row.folderIDs = ["folder-X"]
        context.insert(row)
        try context.save()

        // Construct ChatListViewModel pointed at the same context.
        let vm = ChatListViewModel(client: nil, context: context)
        // Bootstrap may be async; seed chats[] synchronously for the test.
        vm.chats = [Chat(jid: "111@s.whatsapp.net", name: "Alice",
                         lastMessage: "", lastTimestamp: 0, unread: 0)]
        XCTAssertEqual(vm.chats.first?.folderIDs, [])

        vm.refreshFolderIDs(for: "111@s.whatsapp.net")

        XCTAssertEqual(vm.chats.first?.folderIDs, ["folder-X"])
    }

    func testRefreshFolderIDsForAllChats() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let a = PersistedChat(jid: "1@s.whatsapp.net", name: "A")
        a.folderIDs = ["folder-X"]
        let b = PersistedChat(jid: "2@s.whatsapp.net", name: "B")
        b.folderIDs = ["folder-Y"]
        context.insert(a)
        context.insert(b)
        try context.save()

        let vm = ChatListViewModel(client: nil, context: context)
        vm.chats = [
            Chat(jid: "1@s.whatsapp.net", name: "A", lastMessage: "", lastTimestamp: 0, unread: 0),
            Chat(jid: "2@s.whatsapp.net", name: "B", lastMessage: "", lastTimestamp: 0, unread: 0)
        ]

        vm.refreshFolderIDs(for: nil)

        XCTAssertEqual(vm.chats[0].folderIDs, ["folder-X"])
        XCTAssertEqual(vm.chats[1].folderIDs, ["folder-Y"])
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            PersistedFolder.self,
            configurations: config)
    }
}
