import Foundation
import SwiftData

/// Background SwiftData writer for inbound `BridgeMessage` rows.
///
/// `ChatListViewModel.ingest` used to do all of the following on
/// MainActor, per event: a dedupe fetch, an upsert/insert fetch, a
/// `context.save()`, and a synchronous `MessageIndex.shared.upsert`.
/// Bursts (history sync, offline-queue drain) multiplied that cost and
/// blocked the main thread — see Codex audit finding F3.
///
/// The writer owns its own background `ModelContext` bound to the same
/// `ModelContainer` and processes message batches off-main. Per batch:
///
/// 1. For each `BridgeMessage`, look up the existing `PersistedMessage`
///    row by id and merge media / view-once / location / contact fields
///    (the upsert branch). Otherwise insert a new row using the verbatim
///    init that `persistMessage` used.
/// 2. Push `row.indexFields` to `MessageIndex.shared.upsert` (the FTS
///    index is already serial-queue-safe).
/// 3. `context.save()` *once* at the end of the batch — the headline
///    efficiency win vs the per-event save the old path did.
///
/// The returned `[WriteOutcome]` lets MainActor callers update their
/// in-memory `chats` array (preview / unread / push-name resolve /
/// broadcast resolve / notification) without doing the SwiftData
/// round-trip themselves. Ordering is preserved 1:1 with the input
/// batch order.
actor MessageWriter {
    /// One result row per `BridgeMessage` enqueued. `alreadySeen` is
    /// `true` when the message id matched an existing `PersistedMessage`
    /// (replay path) — MainActor uses this to skip unread bumps.
    struct WriteOutcome: Sendable {
        let id: String
        let canonicalChatJID: String
        let alreadySeen: Bool
    }

    private let context: ModelContext
    private let canonicalize: @Sendable (String) -> String

    init(container: ModelContainer,
         canonicalize: @Sendable @escaping (String) -> String) {
        self.context = ModelContext(container)
        self.canonicalize = canonicalize
    }

    /// Persist a batch of inbound messages. Returns one outcome per
    /// input message in the same order. Safe to call from any actor.
    func enqueue(_ batch: [BridgeMessage]) -> [WriteOutcome] {
        var outcomes: [WriteOutcome] = []
        outcomes.reserveCapacity(batch.count)
        for m in batch {
            let id = m.id
            let canonJID = canonicalize(m.chatJID)

            let descriptor = FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.id == id })
            if let existing = try? context.fetch(descriptor).first {
                // Upsert branch — verbatim from the old `persistMessage`
                // upsert block. History-sync replays sometimes carry
                // fresher media refs than what we first persisted; refresh
                // media fields on the existing row instead of letting
                // @Attribute(.unique) silently drop the new arrival.
                if let ref = m.media?.ref?.json, ref != existing.mediaRefJSON {
                    existing.mediaRefJSON = ref
                    existing.mediaExpired = false
                }
                if let p = m.media?.filePath, !p.isEmpty { existing.mediaPath = p }
                if let c = m.media?.caption, !c.isEmpty { existing.mediaCaption = c }
                if let f = m.media?.fileName, !f.isEmpty { existing.mediaFileName = f }
                // T12 fields: re-merge live-location sequence updates and
                // pick up view-once / contact metadata that a later replay
                // may carry. The insert path below threads these on first
                // ingest; this branch keeps them in sync on subsequent
                // updates (e.g. live-location stream sequence bumps).
                if let v = m.isViewOnce { existing.isViewOnce = v }
                if let loc = m.location {
                    existing.locationLat = loc.lat
                    existing.locationLng = loc.lng
                    if !loc.name.isEmpty { existing.locationName = loc.name }
                    if !loc.address.isEmpty { existing.locationAddress = loc.address }
                }
                if m.kind == "location_live" {
                    existing.locationIsLive = true
                    if let seq = m.locationSequence { existing.locationSequence = seq }
                }
                if let card = m.contact {
                    existing.contactVCard = card.vcard
                    existing.contactDisplayName = card.displayName
                }
                outcomes.append(.init(
                    id: id,
                    canonicalChatJID: canonJID,
                    alreadySeen: true))
                continue
            }

            // Insert branch — verbatim from the old `persistMessage`
            // PersistedMessage init.
            let row = PersistedMessage(
                id: id,
                chatJID: canonJID,
                senderJID: m.senderJID,
                fromMe: m.fromMe,
                timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
                kind: m.kind,
                text: m.text,
                mediaPath: m.media?.filePath,
                mediaCaption: m.media?.caption,
                mediaFileName: m.media?.fileName,
                mediaRefJSON: m.media?.ref?.json,
                pollJSON: m.poll?.json,
                isViewOnce: m.isViewOnce ?? false,
                viewOnceLocked: false,
                locationLat: m.location?.lat,
                locationLng: m.location?.lng,
                locationName: m.location?.name,
                locationAddress: m.location?.address,
                locationIsLive: m.kind == "location_live",
                locationSequence: m.locationSequence,
                contactVCard: m.contact?.vcard,
                contactDisplayName: m.contact?.displayName,
                quotedMessageID: m.quoted?.messageID,
                quotedSenderJID: m.quoted?.senderJID,
                quotedFromMe: m.quoted?.fromMe ?? false,
                quotedTextSnippet: m.quoted?.snippet,
                quotedKind: m.quoted?.kind)
            context.insert(row)
            MessageIndex.shared.upsert(row.indexFields)
            outcomes.append(.init(
                id: id,
                canonicalChatJID: canonJID,
                alreadySeen: false))
        }
        // One save per batch — the headline efficiency win vs the old
        // per-event save the MainActor path used to do.
        do {
            try context.save()
        } catch {
            NSLog("[yawac/MessageWriter] save failed for batch of %d: %@",
                  batch.count, String(describing: error))
        }
        return outcomes
    }

    /// Persist a batch of inbound reactions off-main. Matches the upsert /
    /// delete semantics of the original `ChatListViewModel.persistReaction`
    /// (composite key `<targetMessageID>|<senderJID>`), but with one
    /// `context.save()` per batch instead of per event — see F20.
    func enqueueReactions(_ batch: [BridgeReaction]) {
        for r in batch {
            let id = r.targetMessageID
            let sender = r.senderJID
            let descriptor = FetchDescriptor<PersistedReaction>(
                predicate: #Predicate {
                    $0.targetMessageID == id && $0.senderJID == sender
                })
            let ts = Date(timeIntervalSince1970: TimeInterval(r.timestamp))
            let canonChat = canonicalize(r.chatJID)
            if r.emoji.isEmpty {
                if let row = try? context.fetch(descriptor).first {
                    context.delete(row)
                }
            } else if let existing = try? context.fetch(descriptor).first {
                existing.emoji = r.emoji
                existing.timestamp = ts
                existing.chatJID = canonChat
            } else {
                let row = PersistedReaction(
                    chatJID: canonChat,
                    targetMessageID: r.targetMessageID,
                    senderJID: r.senderJID,
                    emoji: r.emoji,
                    timestamp: ts)
                context.insert(row)
            }
        }
        do {
            try context.save()
        } catch {
            NSLog("[yawac/MessageWriter] reaction save failed for batch of %d: %@",
                  batch.count, String(describing: error))
        }
    }

    /// Field-update mutations that the global event stream applies to
    /// existing `PersistedMessage` rows (peer-device edit / revoke /
    /// local-delete / star / message-pin). Sendable so callers can
    /// accumulate a batch on MainActor and hand it off to the writer
    /// actor in one shot — see F21.
    enum MessageMutation: Sendable {
        case localDelete(id: String, chatJID: String)
        case revoke(id: String, chatJID: String, by: String, at: Date)
        case messagePin(id: String, chatJID: String, pinned: Bool, at: Date)
        case star(id: String, chatJID: String, starred: Bool, at: Date)
        case edit(id: String, chatJID: String, newText: String, at: Date)
    }

    /// Apply a batch of `MessageMutation` rows off-main. One fetch per id
    /// (SwiftData's `id == ?` predicate already hits the @Attribute(.unique)
    /// index) and one `context.save()` per batch.
    func enqueueMutations(_ batch: [MessageMutation]) {
        for m in batch {
            switch m {
            case .localDelete(let id, _):
                let descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.id == id })
                if let row = try? context.fetch(descriptor).first {
                    row.locallyDeleted = true
                }
            case .revoke(let id, _, let by, let at):
                let descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.id == id })
                if let row = try? context.fetch(descriptor).first {
                    row.revokedAt = at
                    row.revokedBy = by
                }
            case .messagePin(let id, _, let pinned, let at):
                let descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.id == id })
                if let row = try? context.fetch(descriptor).first {
                    row.pinnedAt = pinned ? at : nil
                }
            case .star(let id, _, let starred, let at):
                let descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.id == id })
                if let row = try? context.fetch(descriptor).first {
                    row.starredAt = starred ? at : nil
                }
            case .edit(let id, _, let newText, let at):
                let descriptor = FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.id == id })
                if let row = try? context.fetch(descriptor).first {
                    row.text = newText
                    row.editedAt = at
                }
            }
        }
        do {
            try context.save()
        } catch {
            NSLog("[yawac/MessageWriter] mutation save failed for batch of %d: %@",
                  batch.count, String(describing: error))
        }
    }
}
