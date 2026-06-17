import XCTest
import UniformTypeIdentifiers
@testable import yawac

final class FolderTransfersTests: XCTestCase {

    func testChatJIDTransferRoundTripsJSON() throws {
        let original = ChatJIDTransfer(jid: "111@s.whatsapp.net")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatJIDTransfer.self, from: data)
        XCTAssertEqual(decoded.jid, "111@s.whatsapp.net")
    }

    func testFolderIDTransferRoundTripsJSON() throws {
        let original = FolderIDTransfer(id: "uuid-1234")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FolderIDTransfer.self, from: data)
        XCTAssertEqual(decoded.id, "uuid-1234")
    }

    func testUTTypesRegistered() {
        XCTAssertEqual(UTType.chatJID.identifier, ChatJIDTransfer.utTypeIdentifier)
        XCTAssertEqual(UTType.folderID.identifier, FolderIDTransfer.utTypeIdentifier)
    }
}
