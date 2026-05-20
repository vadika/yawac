import Foundation

struct UIMessage: Identifiable, Hashable {
    let id: String
    let chatJID: String
    let senderJID: String
    let fromMe: Bool
    let timestamp: Date
    let body: Body

    enum Body: Hashable {
        case text(String)
        case media(kind: String, caption: String?, fileName: String?, localPath: String?)
        case poll(question: String, options: [BridgePollOption], selectableCount: Int)
        case system(String)
    }
}

extension UIMessage {
    enum Status: Hashable {
        case sent
        case delivered
        case read
        case played
    }
}

extension UIMessage {
    init(_ b: BridgeMessage) {
        self.id = b.id
        self.chatJID = b.chatJID
        self.senderJID = b.senderJID
        self.fromMe = b.fromMe
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(b.timestamp))
        switch b.kind {
        case "text":
            self.body = .text(b.text ?? "")
        case "image", "video", "audio", "document", "sticker":
            self.body = .media(kind: b.kind,
                               caption: b.media?.caption,
                               fileName: b.media?.fileName,
                               localPath: b.media?.filePath)
        case "poll":
            if let p = b.poll {
                self.body = .poll(question: p.question,
                                  options: p.options,
                                  selectableCount: p.selectableCount)
            } else {
                self.body = .system(b.kind)
            }
        default:
            self.body = .system(b.kind)
        }
    }
}
