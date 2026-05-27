import Foundation
import Observation
import SwiftData

/// Backs the SHARED MEDIA + FILES sections in `ChatInfoView`. Pulls
/// recent media/document rows for `chatJID` from SwiftData, keeps a
/// short tail in memory for the inspector grid, and reports total
/// counts via `fetchCount` so the header trailing number stays
/// accurate even when the inline preview is capped at 6 cells.
@Observable @MainActor
final class ChatMediaViewModel {
    struct MediaItem: Identifiable, Hashable {
        let id: String          // message id
        let kind: String        // "image" | "video" | "sticker"
        let path: String?
        let timestamp: Date
    }

    struct FileItem: Identifiable, Hashable {
        let id: String
        let fileName: String
        let path: String?
        let timestamp: Date
    }

    struct StarredItem: Identifiable, Hashable {
        let id: String        // message id
        let kind: String      // text / image / video / audio / document / sticker
        let snippet: String   // text body, caption, fileName, or placeholder
        let timestamp: Date
        let starredAt: Date
    }

    private(set) var media: [MediaItem] = []
    private(set) var files: [FileItem] = []
    private(set) var starred: [StarredItem] = []
    private(set) var mediaTotal: Int = 0
    private(set) var filesTotal: Int = 0
    private(set) var starredTotal: Int = 0

    let chatJID: String
    private let context: ModelContext?
    /// Optional external override that maps messageID → on-disk path.
    /// Plumbed from `ConversationViewModel.localPaths` so the info
    /// pane can resolve media paths that landed via the in-flight
    /// MediaCache download (and thus aren't backfilled into
    /// PersistedMessage.mediaPath yet).
    var externalPathResolver: ((String) -> String?)?

    init(chatJID: String, context: ModelContext?) {
        self.chatJID = chatJID
        self.context = context
    }

    private func resolvePath(_ stored: String?, id: String,
                             diskPaths: [String: String]) -> String? {
        if let external = externalPathResolver?(id),
           !external.isEmpty,
           FileManager.default.fileExists(atPath: external) {
            return external
        }
        if let stored, FileManager.default.fileExists(atPath: stored) {
            return stored
        }
        return diskPaths[id]
    }

    /// Builds a (messageID → absolute path) map by scanning the on-disk
    /// media cache. Used to repair MediaItem.path when the persisted
    /// row's mediaPath is nil (e.g. inbound media downloaded after the
    /// row was first saved, where the path wasn't backfilled).
    private func diskMediaPaths() -> [String: String] {
        guard let baseDir = try? AppPaths.mediaCacheURL(),
              let entries = try? FileManager.default.contentsOfDirectory(
                atPath: baseDir.path)
        else { return [:] }
        var map: [String: String] = [:]
        for name in entries {
            // Files are named "<messageID>.<ext>" by MediaCache.
            guard let dot = name.firstIndex(of: ".") else { continue }
            let id = String(name[..<dot])
            map[id] = baseDir.appendingPathComponent(name).path
        }
        return map
    }

    func reload(limit: Int? = 24) {
        guard let context else { return }
        let jid = chatJID
        let mediaKinds: Set<String> = ["image", "video", "sticker"]
        let diskPaths = diskMediaPaths()

        // Inline grid: top 24 most-recent rows (enough for "6 visible
        // + small buffer for next-tick refresh"). The full sheet view
        // can re-query without a limit when it's built.
        var mediaDescriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { p in
                p.chatJID == jid
                && !p.locallyDeleted
                && p.revokedAt == nil
                && (p.kind == "image" || p.kind == "video" || p.kind == "sticker")
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let limit { mediaDescriptor.fetchLimit = limit }

        var filesDescriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { p in
                p.chatJID == jid
                && !p.locallyDeleted
                && p.revokedAt == nil
                && p.kind == "document"
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let limit { filesDescriptor.fetchLimit = limit }

        let mediaRows = (try? context.fetch(mediaDescriptor)) ?? []
        let fileRows = (try? context.fetch(filesDescriptor)) ?? []

        // Starred. SortDescriptor on optional starredAt sorts nils
        // last; we filter nils out via the predicate anyway.
        var starredDescriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { p in
                p.chatJID == jid
                && !p.locallyDeleted
                && p.revokedAt == nil
                && p.starredAt != nil
            },
            sortBy: [SortDescriptor(\.starredAt, order: .reverse)]
        )
        if let limit { starredDescriptor.fetchLimit = limit }
        let starredRows = (try? context.fetch(starredDescriptor)) ?? []

        media = mediaRows.compactMap { row in
            guard mediaKinds.contains(row.kind) else { return nil }
            let resolved = resolvePath(row.mediaPath, id: row.id, diskPaths: diskPaths)
            return MediaItem(id: row.id,
                             kind: row.kind,
                             path: resolved,
                             timestamp: row.timestamp)
        }
        files = fileRows.map { row in
            let resolved = resolvePath(row.mediaPath, id: row.id, diskPaths: diskPaths)
            return FileItem(id: row.id,
                            fileName: row.mediaFileName ?? "Document",
                            path: resolved,
                            timestamp: row.timestamp)
        }

        starred = starredRows.compactMap { row in
            guard let when = row.starredAt else { return nil }
            return StarredItem(id: row.id,
                               kind: row.kind,
                               snippet: Self.snippet(for: row),
                               timestamp: row.timestamp,
                               starredAt: when)
        }

        // Count descriptors mirror the predicates but skip sorting/limits.
        let mediaCountDescriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { p in
                p.chatJID == jid
                && !p.locallyDeleted
                && p.revokedAt == nil
                && (p.kind == "image" || p.kind == "video" || p.kind == "sticker")
            }
        )
        let filesCountDescriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { p in
                p.chatJID == jid
                && !p.locallyDeleted
                && p.revokedAt == nil
                && p.kind == "document"
            }
        )
        let starredCountDescriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { p in
                p.chatJID == jid
                && !p.locallyDeleted
                && p.revokedAt == nil
                && p.starredAt != nil
            }
        )
        mediaTotal = (try? context.fetchCount(mediaCountDescriptor)) ?? media.count
        filesTotal = (try? context.fetchCount(filesCountDescriptor)) ?? files.count
        starredTotal = (try? context.fetchCount(starredCountDescriptor)) ?? starred.count
    }

    private static func snippet(for row: PersistedMessage) -> String {
        if let t = row.text, !t.isEmpty { return t }
        if let c = row.mediaCaption, !c.isEmpty { return c }
        if let n = row.mediaFileName, !n.isEmpty { return n }
        switch row.kind {
        case "image":    return "Photo"
        case "video":    return "Video"
        case "audio":    return "Voice note"
        case "document": return "Document"
        case "sticker":  return "Sticker"
        case "poll":     return "Poll"
        default:         return row.kind
        }
    }
}
