import XCTest
import SwiftData
@testable import yawac

@MainActor
final class FolderRailViewModelCRUDTests: XCTestCase {

    func testCreateFirstFolder() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        vm.loadFolders()
        XCTAssertEqual(vm.folders.count, 0)

        let created = vm.createFolder(name: "Work", atIndex: 0)
        XCTAssertEqual(vm.folders.count, 1)
        XCTAssertEqual(vm.folders[0].id, created.id)
        XCTAssertEqual(created.sortIndex, 0)
    }

    func testCreateSecondFolderAtIndexZeroBumpsExisting() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "First", atIndex: 0)
        _ = vm.createFolder(name: "Second", atIndex: 0)

        XCTAssertEqual(vm.folders.map(\.name), ["Second", "First"])
        XCTAssertEqual(vm.folders.map(\.sortIndex), [0, 1])
    }

    func testRenameFolderPreservesSortIndex() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        let f = vm.createFolder(name: "Old", atIndex: 0)
        vm.renameFolder(id: f.id, to: "New")
        XCTAssertEqual(vm.folders.first?.name, "New")
        XCTAssertEqual(vm.folders.first?.sortIndex, 0)
    }

    func testDeleteFolderScrubsChatMemberships() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let vm = FolderRailViewModel(context: context)
        let f = vm.createFolder(name: "Work", atIndex: 0)

        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "A")
        chat.folderIDs = [f.id, "other-folder"]
        context.insert(chat)
        try context.save()

        vm.deleteFolder(id: f.id)

        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, ["other-folder"])
        XCTAssertEqual(vm.folders.count, 0)
    }

    func testReorderMidToHead() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)
        _ = vm.createFolder(name: "C", atIndex: 2)

        vm.reorder(fromIndex: 2, toIndex: 0)
        XCTAssertEqual(vm.folders.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(vm.folders.map(\.sortIndex), [0, 1, 2])
    }

    func testReorderHeadToTail() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)
        _ = vm.createFolder(name: "C", atIndex: 2)

        vm.reorder(fromIndex: 0, toIndex: 2)
        XCTAssertEqual(vm.folders.map(\.name), ["B", "C", "A"])
    }

    func testReorderNoOp() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)

        vm.reorder(fromIndex: 1, toIndex: 1)
        XCTAssertEqual(vm.folders.map(\.name), ["A", "B"])
    }

    func testReorderOutOfBoundsClamps() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        _ = vm.createFolder(name: "A", atIndex: 0)
        _ = vm.createFolder(name: "B", atIndex: 1)

        // Out-of-bounds: silently no-op (don't crash).
        vm.reorder(fromIndex: 5, toIndex: 0)
        vm.reorder(fromIndex: 0, toIndex: 99)
        XCTAssertEqual(vm.folders.map(\.name), ["A", "B"])
    }

    func testAddChatIsIdempotent() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let vm = FolderRailViewModel(context: context)
        let f = vm.createFolder(name: "Work", atIndex: 0)
        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "A")
        context.insert(chat)
        try context.save()

        vm.addChat(jid: "111@s.whatsapp.net", toFolderID: f.id)
        vm.addChat(jid: "111@s.whatsapp.net", toFolderID: f.id)  // dup

        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, [f.id])
    }

    func testRemoveChat() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)
        let vm = FolderRailViewModel(context: context)
        let f = vm.createFolder(name: "Work", atIndex: 0)
        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "A")
        chat.folderIDs = [f.id, "other"]
        context.insert(chat)
        try context.save()

        vm.removeChat(jid: "111@s.whatsapp.net", fromFolderID: f.id)
        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, ["other"])
    }

    func testDeleteSelectedFolderCollapsesSelectionToAll() throws {
        let container = try Self.makeInMemoryContainer()
        let vm = FolderRailViewModel(context: ModelContext(container))
        let f = vm.createFolder(name: "X", atIndex: 0)
        vm.selection = .custom(folderID: f.id)
        vm.deleteFolder(id: f.id)
        XCTAssertEqual(vm.selection, .all)
    }

    private static func makeInMemoryContainer() throws -> ModelContainer {
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
