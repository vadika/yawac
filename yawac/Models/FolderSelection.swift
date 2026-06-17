import Foundation

/// F91: which rail item is currently selected.
/// Smart folders ("All chats", "Archived") are enum cases, not
/// SwiftData rows. Custom folders carry their PersistedFolder.id.
enum FolderSelection: Equatable, Hashable {
    case all
    case archived
    case custom(folderID: String)

    /// Stable string representation for @AppStorage round-trip.
    /// Reserved value `_archived` for the Archived smart folder; empty
    /// string for All chats; any other string is a folder UUID.
    var storageValue: String {
        switch self {
        case .all: return ""
        case .archived: return "_archived"
        case .custom(let id): return id
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "": self = .all
        case "_archived": self = .archived
        default: self = .custom(folderID: storageValue)
        }
    }

    /// Like `init(storageValue:)` but collapses .custom selections whose
    /// folderID is not in `knownIDs` down to .all. Used at app launch to
    /// recover from a folder that was deleted in a prior session.
    static func resolved(storageValue: String,
                         knownIDs: Set<String>) -> FolderSelection {
        let s = FolderSelection(storageValue: storageValue)
        if case .custom(let id) = s, !knownIDs.contains(id) {
            return .all
        }
        return s
    }
}
