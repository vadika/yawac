import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import AppKit

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

/// F91 v4: NSItemProviderWriting wrapper for FolderIDTransfer so that
/// `.onDrag { NSItemProvider }` can register a folder-ID payload.
/// Needed because `.draggable(FolderIDTransfer(...))` on a SwiftUI
/// `Button` is unreliable on macOS — the button's tap-target wins before
/// the drag distance threshold is met.
final class FolderIDTransferNSObject: NSObject, NSItemProviderWriting {
    let id: String
    init(id: String) { self.id = id }

    static var writableTypeIdentifiersForItemProvider: [String] {
        [FolderIDTransfer.utTypeIdentifier]
    }

    func loadData(withTypeIdentifier typeIdentifier: String,
                  forItemProviderCompletionHandler completionHandler: @escaping (Data?, Error?) -> Void) -> Progress? {
        let data = try? JSONEncoder().encode(FolderIDTransfer(id: id))
        completionHandler(data, nil)
        return nil
    }
}
