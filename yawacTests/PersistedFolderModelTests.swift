import XCTest
import SwiftData
@testable import yawac

@MainActor
final class PersistedFolderModelTests: XCTestCase {

    func testInsertAndFetchPersistedFolder() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let f = PersistedFolder(name: "Work", sortIndex: 0)
        context.insert(f)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PersistedFolder>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Work")
        XCTAssertEqual(fetched.first?.sortIndex, 0)
        XCTAssertFalse(fetched.first?.id.isEmpty ?? true)
    }

    func testUniqueIDConstraint() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let id = "fixed-id-for-test"
        context.insert(PersistedFolder(id: id, name: "A", sortIndex: 0))
        try context.save()

        // Second insert with same id: SwiftData unique constraint upserts.
        context.insert(PersistedFolder(id: id, name: "B", sortIndex: 1))
        try context.save()

        let rows = try context.fetch(FetchDescriptor<PersistedFolder>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "B")
    }

    func testPersistedChatFolderIDsRoundTrip() throws {
        let container = try Self.makeInMemoryContainer()
        let context = ModelContext(container)

        let chat = PersistedChat(jid: "111@s.whatsapp.net", name: "Alice")
        chat.folderIDs = ["folder-1", "folder-2"]
        context.insert(chat)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PersistedChat>())
        XCTAssertEqual(fetched.first?.folderIDs, ["folder-1", "folder-2"])
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
