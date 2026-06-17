import XCTest
@testable import yawac

final class ChatListFolderFilterTests: XCTestCase {

    func testAllSelectionExcludesArchived() {
        let alive = makeChat(jid: "1", archived: false, folderIDs: [])
        let arch  = makeChat(jid: "2", archived: true, folderIDs: [])
        let out = ChatListViewModel.chatsFor(selection: .all,
                                             allChats: [alive, arch])
        XCTAssertEqual(out.map(\.jid), ["1"])
    }

    func testArchivedSelectionIncludesOnlyArchived() {
        let alive = makeChat(jid: "1", archived: false, folderIDs: [])
        let arch  = makeChat(jid: "2", archived: true, folderIDs: ["folder-X"])
        let out = ChatListViewModel.chatsFor(selection: .archived,
                                             allChats: [alive, arch])
        XCTAssertEqual(out.map(\.jid), ["2"])
    }

    func testCustomSelectionMatchesFolderIDs() {
        let inFolder = makeChat(jid: "1", archived: false,
                                 folderIDs: ["folder-X"])
        let outFolder = makeChat(jid: "2", archived: false,
                                  folderIDs: ["folder-Y"])
        let result = ChatListViewModel.chatsFor(
            selection: .custom(folderID: "folder-X"),
            allChats: [inFolder, outFolder])
        XCTAssertEqual(result.map(\.jid), ["1"])
    }

    func testCustomSelectionHidesArchivedEvenIfTagged() {
        let archivedInFolder = makeChat(jid: "1", archived: true,
                                        folderIDs: ["folder-X"])
        let aliveInFolder = makeChat(jid: "2", archived: false,
                                     folderIDs: ["folder-X"])
        let result = ChatListViewModel.chatsFor(
            selection: .custom(folderID: "folder-X"),
            allChats: [archivedInFolder, aliveInFolder])
        XCTAssertEqual(result.map(\.jid), ["2"])
    }

    func testCustomSelectionEmptyWhenNoMatches() {
        let chat = makeChat(jid: "1", archived: false, folderIDs: ["folder-Y"])
        let result = ChatListViewModel.chatsFor(
            selection: .custom(folderID: "folder-X"),
            allChats: [chat])
        XCTAssertEqual(result.count, 0)
    }

    private func makeChat(jid: String, archived: Bool,
                          folderIDs: [String]) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        if archived { c.archivedAt = Date() }
        c.folderIDs = folderIDs
        return c
    }
}
