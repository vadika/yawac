import Foundation
import SwiftData

/// Serial owner of message persistence. Outcomes describe committed source rows;
/// search failures are reported separately and repaired from the source store.
actor MessageWriter {
    struct WriteOutcome: Sendable {
        let id: String
        let canonicalChatJID: String
        let alreadySeen: Bool
    }

    struct ChatPreview: Sendable {
        let jid: String
        let timestamp: Int64
        let text: String
    }

    struct Commit {
        let received: [WriteOutcome]
        let changed: [UIMessage]
        let deletedChats: Set<String>
        let previews: [ChatPreview]
    }

    enum Operation {
        case purgeChat(String)
        case message(BridgeMessage)
        case reaction(BridgeReaction)
        case mutation(MessageMutation)
        case receipt(BridgeReceipt)
        case vote(chat: String, message: String, voter: String, hashes: [String], at: Date)
    }

    enum MessageMutation: Sendable {
        case localDelete(id: String, chatJID: String)
        case revoke(id: String, chatJID: String, by: String, at: Date)
        case messagePin(id: String, chatJID: String, pinned: Bool, at: Date)
        case star(id: String, chatJID: String, starred: Bool, at: Date)
        case edit(id: String, chatJID: String, newText: String, at: Date)
        case delivery(id: String, status: String)
        case mediaPath(id: String, path: String)
        case mediaExpired(id: String, expired: Bool)
        case mediaRetry(id: String, directPath: String)
        case viewOnce(id: String)
    }


    private var pendingMutations: [String: [MessageMutation]] = [:]
    private var pendingOrder: [String] = []
    private let context: ModelContext
    private let canonicalize: @Sendable (String) -> String
    private let index: MessageIndex
    private var indexIdentity: String?
    private let beforeSave: @Sendable () throws -> Void

    init(container: ModelContainer,
         index: MessageIndex = .shared,
         beforeSave: @Sendable @escaping () throws -> Void = {},
         canonicalize: @Sendable @escaping (String) -> String) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        self.index = index
        self.beforeSave = beforeSave
        self.canonicalize = canonicalize
    }

    func enqueue(_ batch: [BridgeMessage]) throws -> [WriteOutcome] {
        try write(batch.map(Operation.message)).received
    }

    func enqueueReactions(_ batch: [BridgeReaction]) throws {
        _ = try write(batch.map(Operation.reaction))
    }

    func enqueueMutations(_ batch: [MessageMutation]) throws {
        _ = try write(batch.map(Operation.mutation))
    }

    func write(_ operations: [Operation]) throws -> Commit {
        let previousPending = pendingMutations
        let previousOrder = pendingOrder
        var outcomes: [WriteOutcome] = []
        var changed: [String: PersistedMessage] = [:]
        var consumedPaths: [String] = []
        var deletedChats: Set<String> = []
        var removedIDs: [String] = []
        var previews: [ChatPreview] = []
        do {
            for operation in operations {
                switch operation {
                case .purgeChat(let jid):
                    let ids = try deleteChatRows(jid)
                    removedIDs += ids
                    for id in ids { changed.removeValue(forKey: id) }
                    deletedChats.insert(jid)
                case .message(let message):
                    let existing = try fetch(message.id)
                    deletedChats.remove(canonicalize(message.chatJID))
                    let jid = canonicalize(message.chatJID)
                    let row = existing ?? PersistedMessage(
                        id: message.id, chatJID: jid, senderJID: message.senderJID,
                        fromMe: message.fromMe,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(message.timestamp)),
                        kind: message.kind)
                    if existing == nil { context.insert(row) }
                    try row.merge(message, canonicalChatJID: jid)
                    changed[row.id] = row
                    if let pending = pendingMutations.removeValue(forKey: row.id) {
                        pendingOrder.removeAll { $0 == row.id }
                        for mutation in pending { _ = try apply(mutation) }
                    }
                    outcomes.append(.init(id: row.id, canonicalChatJID: jid,
                                          alreadySeen: existing != nil))
                case .receipt(let receipt):
                    for id in receipt.messageIDs {
                        let mutation = MessageMutation.delivery(id: id, status: receipt.status)
                        if let row = try apply(mutation) { changed[id] = row } else { stash(mutation) }
                    }
                case .vote(let chat, let message, let voter, let hashes, let at):
                    try applyVote(chat: chat, message: message, voter: voter, hashes: hashes, at: at)
                case .reaction(let reaction):
                    try apply(reaction)
                case .mutation(let mutation):
                    if case .viewOnce(let id) = mutation, let row = try fetch(id), row.isViewOnce,
                       let path = row.mediaPath { consumedPaths.append(path) }
                    if let row = try apply(mutation) { changed[row.id] = row }
                    else { stash(mutation) }
                }
            }
            for jid in Set(changed.values.map(\.chatJID)) {
                var descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate {
                    $0.chatJID == jid && $0.kind != "system" && $0.kind != "protocol"
                }, sortBy: [SortDescriptor(\.timestamp, order: .reverse), SortDescriptor(\.id, order: .reverse)])
                descriptor.fetchLimit = 1
                if let row = try context.fetch(descriptor).first {
                    previews.append(ChatPreview(jid: jid, timestamp: Int64(row.timestamp.timeIntervalSince1970), text: row.sidebarPreview))
                }
            }
            try beforeSave()
            try context.save()
        } catch {
            context.rollback()
            pendingMutations = previousPending
            pendingOrder = previousOrder
            throw error
        }
        for path in consumedPaths { try? FileManager.default.removeItem(atPath: path) }
        // The source commit succeeded. An index error must never cause a
        // caller to retry a network send that has already succeeded.
        do {
            try index.apply(upserts: changed.values.filter(\.searchable).map(\.indexFields),
                            removing: removedIDs + changed.values.filter { !$0.searchable }.map(\.id))
        } catch {
            index.reportFailure(error)
        }
        return Commit(received: outcomes, changed: changed.values.map(\.uiMessage), deletedChats: deletedChats, previews: previews)
    }

    func purgeChat(_ jid: String) throws { _ = try write([.purgeChat(jid)]) }

    private func deleteChatRows(_ jid: String) throws -> [String] {
        let messages = try context.fetch(FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.chatJID == jid }))
        let ids = messages.map(\.id)
        for row in messages { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistedReaction>(predicate: #Predicate { $0.chatJID == jid })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistedPollVote>(predicate: #Predicate { $0.chatJID == jid })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistedChat>(predicate: #Predicate { $0.jid == jid })) { context.delete(row) }
        for id in ids { pendingMutations.removeValue(forKey: id) }
        pendingOrder.removeAll { ids.contains($0) }
        return ids
    }

    func maintainStore() {
        let url = context.container.configurations.first!.url
        SwiftDataIndexes.ensure(at: url)
        do { try SwiftDataMaintenance.pruneHistory(at: url, keepDays: 7) }
        catch { NSLog("[yawac/maintenance] %@", error.localizedDescription) }
        SwiftDataMaintenance.maintainIfNeeded(at: url)
    }

    func prepareChats() throws {
        let pairs = try context.fetch(FetchDescriptor<PersistedChat>()).compactMap { row -> (lid: String, pn: String)? in
            let canonical = canonicalize(row.jid)
            return row.jid == canonical ? nil : (row.jid, canonical)
        }
        if !pairs.isEmpty { try mergeChats(pairs) }
    }

    /// Merge metadata and reparent the complete conversation in one source commit.
    func mergeChats(_ pairs: [(lid: String, pn: String)]) throws {
        do {
            for (lid, pn) in pairs where lid != pn {
                let source = try context.fetch(FetchDescriptor<PersistedChat>(predicate: #Predicate { $0.jid == lid })).first
                let target = try context.fetch(FetchDescriptor<PersistedChat>(predicate: #Predicate { $0.jid == pn })).first
                if let source, let target {
                    target.unread += source.unread
                    if source.lastTimestamp > target.lastTimestamp {
                        target.lastTimestamp = source.lastTimestamp
                        target.lastMessageText = source.lastMessageText
                    }
                    if target.name.isEmpty || target.name == pn { target.name = source.name }
                    context.delete(source)
                } else { source?.jid = pn }
                for row in try context.fetch(FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.chatJID == lid })) { row.chatJID = pn }
                for row in try context.fetch(FetchDescriptor<PersistedReaction>(predicate: #Predicate { $0.chatJID == lid })) { row.chatJID = pn }
                for row in try context.fetch(FetchDescriptor<PersistedPollVote>(predicate: #Predicate { $0.chatJID == lid })) { row.chatJID = pn }
            }
            try beforeSave()
            try context.save()
        } catch { context.rollback(); throw error }
        do { try index.reconcile() } catch { index.reportFailure(error) }
    }

    /// Compatibility repairs run before history reads, once per configured store/chat.
    func prepareHistory(chatJID jid: String) throws {
        let prefix = context.container.configurations.first!.url.path
        let scrubKey = "yawac.cvm.scrubbedChat.\(jid)"
        let sweepKey = "yawac.cvm.sweptChat.\(jid)"
        let key = "yawac.historyPrepared.\(prefix).\(jid)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var repaired = false
        do {
            if let at = jid.firstIndex(of: "@") {
                let user = String(jid[..<at])
                for row in try context.fetch(FetchDescriptor<PersistedMessage>(
                    predicate: #Predicate { $0.chatJID != jid && $0.chatJID.contains(user) }))
                where canonicalize(row.chatJID) == jid { row.chatJID = jid }
            }
            for row in try context.fetch(FetchDescriptor<PersistedMessage>(
                predicate: #Predicate { $0.chatJID == jid && ($0.kind == "reaction" || $0.kind == "protocol") })) {
                context.delete(row)
            }
            repaired = context.hasChanges
            try beforeSave()
            try context.save()
        } catch { context.rollback(); throw error }
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.set(true, forKey: scrubKey)
        UserDefaults.standard.set(true, forKey: sweepKey)
        if repaired {
            do { try index.reconcile() } catch { index.reportFailure(error) }
        }
    }

    func configureIndex(ownJID: String, ownPushName: String) {
        let identity = "\(ownJID)|\(ownPushName)"
        guard indexIdentity != identity else { return }
        indexIdentity = identity
        index.setOwnBareJID(ownJID)
        index.setOwnPushName(ownPushName)
        index.setCanonicalizer(canonicalize)
        do { try index.reconcile() } catch { index.reportFailure(error) }
    }

    private func stash(_ mutation: MessageMutation) {
        let id: String
        switch mutation {
        case .localDelete(let key, _), .revoke(let key, _, _, _),
             .messagePin(let key, _, _, _), .star(let key, _, _, _), .edit(let key, _, _, _),
             .delivery(let key, _), .mediaPath(let key, _), .mediaExpired(let key, _),
             .mediaRetry(let key, _), .viewOnce(let key): id = key
        }
        if pendingMutations[id] == nil { pendingOrder.append(id) }
        // Bound both unknown target count and repeated updates for one target.
        var pending = pendingMutations[id] ?? []
        pending.append(mutation)
        if pending.count > 32 { pending.removeFirst() }
        pendingMutations[id] = pending
        if pendingOrder.count > 256 { pendingMutations.removeValue(forKey: pendingOrder.removeFirst()) }
    }

    private func fetch(_ id: String) throws -> PersistedMessage? {
        try context.fetch(FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id })).first
    }

    private func apply(_ reaction: BridgeReaction) throws {
        let key = "\(reaction.targetMessageID)|\(reaction.senderJID)"
        let existing = try context.fetch(FetchDescriptor<PersistedReaction>(
            predicate: #Predicate { $0.compositeKey == key })).first
        let timestamp = Date(timeIntervalSince1970: TimeInterval(reaction.timestamp))
        if let existing, existing.timestamp > timestamp { return }
        if reaction.emoji.isEmpty {
            if let existing { context.delete(existing) }
        } else if let existing {
            existing.emoji = reaction.emoji
            existing.timestamp = timestamp
            existing.chatJID = canonicalize(reaction.chatJID)
        } else {
            context.insert(PersistedReaction(
                chatJID: canonicalize(reaction.chatJID),
                targetMessageID: reaction.targetMessageID, senderJID: reaction.senderJID,
                emoji: reaction.emoji, timestamp: timestamp))
        }
    }

    private func applyVote(chat: String, message: String, voter: String, hashes: [String], at: Date) throws {
        let voter = canonicalize(voter)
        let key = "\(message)|\(voter)"
        let json = String(data: try JSONEncoder().encode(hashes), encoding: .utf8)!
        if let row = try context.fetch(FetchDescriptor<PersistedPollVote>(
            predicate: #Predicate { $0.compositeKey == key })).first {
            guard row.timestamp <= at else { return }
            row.optionHashesJSON = json
            row.timestamp = at
            row.chatJID = canonicalize(chat)
        } else {
            context.insert(PersistedPollVote(chatJID: canonicalize(chat), pollMessageID: message,
                                            voterJID: voter, optionHashesJSON: json, timestamp: at))
        }
    }

    private func apply(_ mutation: MessageMutation) throws -> PersistedMessage? {
        switch mutation {
        case .delivery(let id, let status):
            let row = try fetch(id)
            let rank = ["sent": 0, "delivered": 1, "played": 2, "read": 3]
            if let row, (rank[status] ?? 0) > (rank[row.deliveryStatus] ?? 0) { row.deliveryStatus = status }
            return row
        case .mediaPath(let id, let path):
            let row = try fetch(id)
            if row?.viewOnceLocked == false { row?.mediaPath = path }
            return row
        case .mediaExpired(let id, let expired):
            let row = try fetch(id)
            row?.mediaExpired = expired
            return row
        case .mediaRetry(let id, let path):
            let row = try fetch(id)
            if let old = row?.mediaRefJSON {
                var ref = try JSONSerialization.jsonObject(with: Data(old.utf8)) as? [String: Any] ?? [:]
                ref["direct_path"] = path
                row?.mediaRefJSON = String(data: try JSONSerialization.data(withJSONObject: ref), encoding: .utf8)
                row?.mediaExpired = false
            }
            return row
        case .viewOnce(let id):
            let row = try fetch(id)
            if let row, row.isViewOnce, !row.viewOnceLocked {
                row.viewOnceLocked = true
                row.viewOnceRevealedAt = .now
                row.mediaCaption = nil
                row.mediaPath = nil
            }
            return row
        case .localDelete(let id, _):
            let row = try fetch(id)
            row?.locallyDeleted = true
            return row
        case .revoke(let id, _, let by, let at):
            let row = try fetch(id)
            if let row, row.revokedAt == nil || row.revokedAt! <= at {
                row.revokedAt = at
                row.revokedBy = by
            }
            return row
        case .messagePin(let id, _, let pinned, let at):
            let row = try fetch(id)
            row?.pinnedAt = pinned ? at : nil
            return row
        case .star(let id, _, let starred, let at):
            let row = try fetch(id)
            row?.starredAt = starred ? at : nil
            return row
        case .edit(let id, _, let text, let at):
            let row = try fetch(id)
            if let row, row.editedAt == nil || row.editedAt! <= at {
                row.text = text
                row.editedAt = at
            }
            return row
        }
    }
}
