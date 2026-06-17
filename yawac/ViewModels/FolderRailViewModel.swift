import Foundation
import Observation
import SwiftData

/// F91: state owner for the folder rail.
///
/// Holds the loaded folder list (sorted by sortIndex), the current
/// selection, and the per-folder unread badge totals. CRUD methods
/// persist directly to the injected ModelContext and re-load folders
/// to refresh `self.folders`.
@Observable @MainActor
final class FolderRailViewModel {

    var folders: [PersistedFolder] = []
    var selection: FolderSelection = .all
    var unreadByFolderID: [String: Int] = [:]
    var allUnread: Int = 0
    var archivedUnread: Int = 0

    @ObservationIgnored private let context: ModelContext
    /// F91 hotfix: back-reference to the chat list so rail mutations can
    /// sync in-memory Chat.folderIDs immediately after persisting.
    @ObservationIgnored weak var chatList: ChatListViewModel?

    init(context: ModelContext, chatList: ChatListViewModel? = nil) {
        self.context = context
        self.chatList = chatList
    }

    // MARK: - Load

    func loadFolders() {
        let descriptor = FetchDescriptor<PersistedFolder>(
            sortBy: [SortDescriptor(\.sortIndex, order: .forward)])
        folders = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - CRUD

    @discardableResult
    func createFolder(name: String, atIndex insertIdx: Int) -> PersistedFolder {
        loadFolders()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = max(0, min(insertIdx, folders.count))
        // Bump sortIndex on all folders at or after target.
        for f in folders where f.sortIndex >= target {
            f.sortIndex += 1
        }
        let new = PersistedFolder(name: trimmed.isEmpty ? "Folder" : trimmed,
                                  sortIndex: target)
        context.insert(new)
        try? context.save()
        loadFolders()
        return new
    }

    func renameFolder(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let f = folders.first(where: { $0.id == id }) else { return }
        f.name = trimmed
        try? context.save()
        loadFolders()
    }

    func deleteFolder(id: String) {
        // Collapse selection BEFORE delete so the view doesn't try to
        // render a folder that's about to disappear.
        if selection == .custom(folderID: id) {
            selection = .all
        }
        // Scrub chat memberships first.
        let chatDescriptor = FetchDescriptor<PersistedChat>()
        let chats = (try? context.fetch(chatDescriptor)) ?? []
        for c in chats where c.folderIDs.contains(id) {
            c.folderIDs.removeAll { $0 == id }
        }
        // Delete the folder row.
        if let f = folders.first(where: { $0.id == id }) {
            context.delete(f)
        }
        try? context.save()
        loadFolders()
        // F91 hotfix: scrub every in-memory Chat.folderIDs (deleteFolder
        // removed this folder's id from every PersistedChat on disk).
        chatList?.refreshFolderIDs(for: nil)
    }

    func reorder(fromIndex: Int, toIndex: Int) {
        loadFolders()
        guard fromIndex >= 0, fromIndex < folders.count else { return }
        guard toIndex >= 0, toIndex < folders.count else { return }
        guard fromIndex != toIndex else { return }

        var working = folders
        let moved = working.remove(at: fromIndex)
        working.insert(moved, at: toIndex)
        // Reassign sortIndex by working order.
        for (i, f) in working.enumerated() {
            f.sortIndex = i
        }
        try? context.save()
        loadFolders()
    }

    // MARK: - Membership

    func addChat(jid: String, toFolderID folderID: String) {
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        guard let c = (try? context.fetch(descriptor))?.first else { return }
        if !c.folderIDs.contains(folderID) {
            c.folderIDs.append(folderID)
            try? context.save()
        }
        // F91 hotfix: sync the updated folderIDs back into the in-memory
        // chat list so chatsFor(.custom) sees the change immediately.
        chatList?.refreshFolderIDs(for: jid)
    }

    func removeChat(jid: String, fromFolderID folderID: String) {
        let descriptor = FetchDescriptor<PersistedChat>(
            predicate: #Predicate { $0.jid == jid })
        guard let c = (try? context.fetch(descriptor))?.first else { return }
        if c.folderIDs.contains(folderID) {
            c.folderIDs.removeAll { $0 == folderID }
            try? context.save()
        }
        // F91 hotfix: sync the updated folderIDs back into the in-memory cache.
        chatList?.refreshFolderIDs(for: jid)
    }

    // MARK: - Badge compute (implemented in Task 5)

    func refreshBadges(chats: [Chat]) {
        var byFolder: [String: Int] = [:]
        var all = 0
        var archived = 0
        for c in chats {
            guard c.unread > 0 else { continue }
            if c.archivedAt != nil {
                archived += c.unread
                continue
            }
            all += c.unread
            for fid in c.folderIDs {
                byFolder[fid, default: 0] += c.unread
            }
        }
        self.unreadByFolderID = byFolder
        self.allUnread = all
        self.archivedUnread = archived
    }
}
