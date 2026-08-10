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
    struct MediaItem: Identifiable, Hashable, Sendable {
        let id: String          // message id
        let kind: String        // "image" | "video" | "sticker"
        let path: String?
        let timestamp: Date
    }

    struct FileItem: Identifiable, Hashable, Sendable {
        let id: String
        let fileName: String
        let path: String?
        let timestamp: Date
    }

    struct StarredItem: Identifiable, Hashable, Sendable {
        let id: String        // message id
        let kind: String      // text / image / video / audio / document / sticker
        let snippet: String   // text body, caption, fileName, or placeholder
        let timestamp: Date
        let starredAt: Date
    }

    struct QuerySnapshot: Sendable {
        let media: [MediaItem]
        let files: [FileItem]
        let starred: [StarredItem]
        let mediaTotal: Int
        let filesTotal: Int
        let starredTotal: Int
    }

    private(set) var media: [MediaItem] = []
    private(set) var files: [FileItem] = []
    private(set) var starred: [StarredItem] = []
    private(set) var mediaTotal: Int = 0
    private(set) var filesTotal: Int = 0
    private(set) var starredTotal: Int = 0

    let chatJID: String
    private let container: ModelContainer?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadRevision = 0
    /// Optional external override that maps messageID → on-disk path.
    /// Plumbed from `ConversationViewModel.localPaths` so the info
    /// pane can resolve media paths that landed via the in-flight
    /// MediaCache download (and thus aren't backfilled into
    /// PersistedMessage.mediaPath yet).
    var externalPathResolver: ((String) -> String?)?

    init(chatJID: String, context: ModelContext?) {
        self.chatJID = chatJID
        self.container = context?.container
    }

    deinit { reloadTask?.cancel() }

    nonisolated private static func resolvePath(
        _ stored: String?, id: String, diskPaths: [String: String]
    ) -> String? {
        if let stored, FileManager.default.fileExists(atPath: stored) {
            return stored
        }
        return diskPaths[id]
    }

    /// Builds a (messageID → absolute path) map by scanning the on-disk
    /// media cache. Used to repair MediaItem.path when the persisted
    /// row's mediaPath is nil (e.g. inbound media downloaded after the
    /// row was first saved, where the path wasn't backfilled).
    nonisolated private static func diskMediaPaths() -> [String: String] {
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
        guard let container else { return }
        reloadRevision += 1
        let revision = reloadRevision
        let jid = chatJID
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.buildSnapshot(chatJID: jid, container: container,
                                   limit: limit)
            }.value
            guard let self, !Task.isCancelled,
                  self.reloadRevision == revision else { return }
            self.apply(snapshot)
        }
    }

    /// Runs every SwiftData fetch/count, row projection, media-cache scan,
    /// and stored-path file probe on a background context. Only value types
    /// cross back to MainActor.
    nonisolated static func buildSnapshot(
        chatJID jid: String,
        container: ModelContainer,
        limit: Int?
    ) -> QuerySnapshot {
        let context = ModelContext(container)
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

        let media: [MediaItem] = mediaRows.compactMap { row in
            guard mediaKinds.contains(row.kind) else { return nil }
            let resolved = resolvePath(row.mediaPath, id: row.id,
                                       diskPaths: diskPaths)
            return MediaItem(id: row.id,
                             kind: row.kind,
                             path: resolved,
                             timestamp: row.timestamp)
        }
        let files: [FileItem] = fileRows.map { row in
            let resolved = resolvePath(row.mediaPath, id: row.id,
                                       diskPaths: diskPaths)
            return FileItem(id: row.id,
                            fileName: row.mediaFileName ?? "Document",
                            path: resolved,
                            timestamp: row.timestamp)
        }

        let starred: [StarredItem] = starredRows.compactMap { row in
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
        return QuerySnapshot(
            media: media,
            files: files,
            starred: starred,
            mediaTotal: (try? context.fetchCount(mediaCountDescriptor)) ?? media.count,
            filesTotal: (try? context.fetchCount(filesCountDescriptor)) ?? files.count,
            starredTotal: (try? context.fetchCount(starredCountDescriptor)) ?? starred.count)
    }

    private func apply(_ snapshot: QuerySnapshot) {
        // The external resolver reads the open conversation's in-flight
        // localPaths dictionary, so consult it only on MainActor. Those paths
        // were just produced by MediaCache and do not need another disk probe.
        if let externalPathResolver {
            media = snapshot.media.map { item in
                guard let external = externalPathResolver(item.id),
                      !external.isEmpty else { return item }
                return MediaItem(id: item.id, kind: item.kind, path: external,
                                 timestamp: item.timestamp)
            }
            files = snapshot.files.map { item in
                guard let external = externalPathResolver(item.id),
                      !external.isEmpty else { return item }
                return FileItem(id: item.id, fileName: item.fileName,
                                path: external, timestamp: item.timestamp)
            }
        } else {
            media = snapshot.media
            files = snapshot.files
        }
        starred = snapshot.starred
        mediaTotal = snapshot.mediaTotal
        filesTotal = snapshot.filesTotal
        starredTotal = snapshot.starredTotal
    }

    nonisolated private static func snippet(for row: PersistedMessage) -> String {
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
