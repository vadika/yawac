import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ConversationViewModel {
    let chatJID: String
    var messages: [UIMessage] = []
    var draft: String = ""
    var peerTyping: Bool = false
    var receiptStatus: [String: UIMessage.Status] = [:]
    let client: WAClient
    private let context: ModelContext?

    init(chatJID: String, client: WAClient, context: ModelContext? = nil) {
        self.chatJID = chatJID
        self.client = client
        self.context = context
    }

    func loadHistory() {
        guard let context else { return }
        let jid = chatJID
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatJID == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        if let rows = try? context.fetch(descriptor) {
            self.messages = rows.map { p in
                UIMessage(
                    id: p.id,
                    chatJID: p.chatJID,
                    senderJID: p.senderJID,
                    fromMe: p.fromMe,
                    timestamp: p.timestamp,
                    body: p.kind == "text"
                        ? .text(p.text ?? "")
                        : .media(kind: p.kind, caption: p.mediaCaption, localPath: p.mediaPath))
            }
        }
    }

    func sendDraft() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        do {
            let res = try client.sendText(chatJID, body)
            let m = UIMessage(
                id: res.messageID,
                chatJID: chatJID,
                senderJID: "me",
                fromMe: true,
                timestamp: Date(timeIntervalSince1970: TimeInterval(res.timestamp)),
                body: .text(body))
            messages.append(m)
            receiptStatus[m.id] = .sent
            persistOutgoing(m, kind: "text", text: body)
        } catch {
            messages.append(UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send failed: \(error.localizedDescription)")))
        }
    }

    func ingest(_ b: BridgeMessage) {
        guard b.chatJID == chatJID else { return }
        // Dedupe by id (echo of fromMe send may arrive after local optimistic append)
        if messages.contains(where: { $0.id == b.id }) { return }
        messages.append(UIMessage(b))
        persist(b)
    }

    func setTyping(_ typing: Bool) {
        try? client.sendTyping(chatJID, typing)
    }

    func sendImage(at url: URL) async {
        let caption = draft
        do {
            let res = try client.sendImage(chatJID, path: url.path, caption: caption)
            receiptStatus[res.messageID] = .sent
            draft = ""
        } catch {
            messages.append(UIMessage(
                id: UUID().uuidString,
                chatJID: chatJID,
                senderJID: "system",
                fromMe: false,
                timestamp: .now,
                body: .system("send image failed: \(error.localizedDescription)")))
        }
    }

    private func persist(_ m: BridgeMessage) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id,
            chatJID: m.chatJID,
            senderJID: m.senderJID,
            fromMe: m.fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
            kind: m.kind,
            text: m.text,
            mediaPath: m.media?.filePath,
            mediaCaption: m.media?.caption)
        context.insert(row)
        try? context.save()
    }

    private func persistOutgoing(_ m: UIMessage, kind: String, text: String?) {
        guard let context else { return }
        let row = PersistedMessage(
            id: m.id, chatJID: m.chatJID, senderJID: m.senderJID,
            fromMe: m.fromMe, timestamp: m.timestamp, kind: kind, text: text)
        context.insert(row)
        try? context.save()
    }

    func applyReceipt(_ r: BridgeReceipt) {
        let status: UIMessage.Status
        switch r.status {
        case "read":      status = .read
        case "played":    status = .played
        case "delivered": status = .delivered
        default:          status = .sent
        }
        for id in r.messageIDs {
            // Only downgrade-prevent: read > delivered > sent
            if let existing = receiptStatus[id] {
                if rank(status) > rank(existing) {
                    receiptStatus[id] = status
                }
            } else {
                receiptStatus[id] = status
            }
        }
    }

    private func rank(_ s: UIMessage.Status) -> Int {
        switch s {
        case .sent:      return 0
        case .delivered: return 1
        case .played:    return 2
        case .read:      return 3
        }
    }
}
