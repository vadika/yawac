import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// F91: drag payload — a single chat JID being dragged from a chat
/// row onto a folder rail item. Custom UT type avoids collision with
/// public file/URL drop handlers that might otherwise eat the drop.
struct ChatJIDTransfer: Codable, Transferable {
    let jid: String

    static let utTypeIdentifier = "dev.vadikas.yawac.chatjid"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .chatJID)
    }
}

/// F91: drag payload — a folder rail item being dragged to reorder.
struct FolderIDTransfer: Codable, Transferable {
    let id: String

    static let utTypeIdentifier = "dev.vadikas.yawac.folderid"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .folderID)
    }
}

extension UTType {
    static let chatJID = UTType(exportedAs: ChatJIDTransfer.utTypeIdentifier)
    static let folderID = UTType(exportedAs: FolderIDTransfer.utTypeIdentifier)
}
