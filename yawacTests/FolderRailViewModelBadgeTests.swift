import XCTest
import SwiftData
@testable import yawac

@MainActor
final class FolderRailViewModelBadgeTests: XCTestCase {

    func testEmptyChatListZeroesAllBadges() throws {
        let vm = try makeVM()
        vm.refreshBadges(chats: [])
        XCTAssertEqual(vm.allUnread, 0)
        XCTAssertEqual(vm.archivedUnread, 0)
        XCTAssertEqual(vm.unreadByFolderID, [:])
    }

    func testUnreadOnNonArchivedChatBumpsAllAndFolder() throws {
        let vm = try makeVM()
        var c = makeChat(jid: "111@s.whatsapp.net", unread: 3,
                        folderIDs: ["folder-A"], archived: false)
        vm.refreshBadges(chats: [c])
        XCTAssertEqual(vm.allUnread, 3)
        XCTAssertEqual(vm.unreadByFolderID, ["folder-A": 3])
        XCTAssertEqual(vm.archivedUnread, 0)
    }

    func testUnreadOnArchivedChatBumpsOnlyArchived() throws {
        let vm = try makeVM()
        let c = makeChat(jid: "222@s.whatsapp.net", unread: 2,
                        folderIDs: ["folder-A"], archived: true)
        vm.refreshBadges(chats: [c])
        XCTAssertEqual(vm.archivedUnread, 2)
        XCTAssertEqual(vm.allUnread, 0)
        XCTAssertEqual(vm.unreadByFolderID, [:],
                       "archived chat must not bump its custom folder badge")
    }

    func testMultipleFoldersSummedIndependently() throws {
        let vm = try makeVM()
        let a = makeChat(jid: "1@s.whatsapp.net", unread: 5,
                        folderIDs: ["f1", "f2"], archived: false)
        let b = makeChat(jid: "2@s.whatsapp.net", unread: 2,
                        folderIDs: ["f1"], archived: false)
        vm.refreshBadges(chats: [a, b])
        XCTAssertEqual(vm.allUnread, 7)
        XCTAssertEqual(vm.unreadByFolderID, ["f1": 7, "f2": 5])
    }

    func testZeroUnreadIgnored() throws {
        let vm = try makeVM()
        let c = makeChat(jid: "0@s.whatsapp.net", unread: 0,
                        folderIDs: ["f1"], archived: false)
        vm.refreshBadges(chats: [c])
        XCTAssertEqual(vm.allUnread, 0)
        XCTAssertEqual(vm.unreadByFolderID, [:])
    }

    // MARK: helpers

    @MainActor
    private func makeVM() throws -> FolderRailViewModel {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: PersistedMessage.self,
            PersistedChat.self,
            PersistedReaction.self,
            PersistedPollVote.self,
            PersistedFolder.self,
            configurations: config)
        return FolderRailViewModel(context: ModelContext(container))
    }

    private func makeChat(jid: String,
                          unread: Int,
                          folderIDs: [String],
                          archived: Bool) -> Chat {
        var c = Chat(jid: jid, name: "Test",
                     lastMessage: "", lastTimestamp: 0, unread: unread)
        c.folderIDs = folderIDs
        if archived { c.archivedAt = Date() }
        return c
    }
}
