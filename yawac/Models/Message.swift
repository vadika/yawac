import Foundation

struct LocationPayload: Hashable, Sendable {
    let lat: Double
    let lng: Double
    let name: String
    let address: String
}

struct ContactPayload: Hashable, Sendable {
    let jid: String
    let displayName: String
    let phone: String
    /// Derived from (jid, name, phone). VCardBuilder.build is pure-
    /// deterministic, so re-synthesizing on read costs less than
    /// the per-payload string we used to keep around — and inbound
    /// vCards collapsed to the same shape here anyway since yawac
    /// never surfaced any field beyond name + phone + waid.
    var vcard: String {
        VCardBuilder.build(jid: jid, name: displayName, phone: phone)
    }

    /// Build from a raw vCard string + displayName. waid (if present)
    /// becomes both the jid (`<waid>@s.whatsapp.net`) and the phone
    /// (`+<waid>`); missing waid leaves both empty so the renderer
    /// falls back to the name-only row.
    static func fromVCard(_ vcard: String, displayName: String) -> ContactPayload {
        let waid = VCardBuilder.parseWAID(vcard) ?? ""
        let jid = waid.isEmpty ? "" : "\(waid)@s.whatsapp.net"
        let phone = waid.isEmpty ? "" : "+\(waid)"
        return ContactPayload(jid: jid, displayName: displayName, phone: phone)
    }
}

struct UIMessage: Identifiable, Hashable, Sendable {
    let id: String
    let chatJID: String
    let senderJID: String
    let fromMe: Bool
    let timestamp: Date
    let body: Body
    var quotedMessageID: String? = nil
    var quotedSenderJID: String? = nil
    var quotedFromMe: Bool = false
    var quotedTextSnippet: String? = nil
    var quotedKind: String? = nil
    var editedAt: Date? = nil
    var revokedAt: Date? = nil
    var revokedBy: String? = nil
    var locallyDeleted: Bool = false
    var starredAt: Date? = nil
    var pinnedAt: Date? = nil
    var isForwarded: Bool = false
    var isViewOnce: Bool = false
    /// Mirrors PersistedMessage.viewOnceLocked — set once the user has
    /// revealed the view-once envelope so we permanently render the
    /// "You viewed this once" lock instead of the reveal CTA. Default
    /// false; populated from the persisted row in loadHistory + after
    /// ViewOnceReveal.reveal(_:) flips it.
    var viewOnceLocked: Bool = false
    /// F38: image / video pixel dimensions captured from the sender's
    /// upload metadata. Lets MessageRow size the bubble's reserved
    /// space to the final aspect ratio BEFORE the thumbnail decode
    /// finishes, eliminating the placeholder → image layout reflow
    /// the user perceived as "I see how the images are drawn" while
    /// scrolling. Both nil for non-image/video kinds + pre-F38
    /// persisted rows.
    var mediaWidth: Int? = nil
    var mediaHeight: Int? = nil

    enum Body: Hashable, Sendable {
        case text(String)
        /// `waveform` carries the raw amplitude bytes (WhatsApp ships 64
        /// values 0-100) for voice notes — nil for older messages and
        /// non-audio kinds. `isPTT` flips the audio bubble between the
        /// vertical-bar waveform view (true) and the plain progress
        /// bar (false / music clip).
        case media(kind: String, caption: String?, fileName: String?,
                   localPath: String?, waveform: Data? = nil,
                   isPTT: Bool = false)
        case poll(question: String, options: [BridgePollOption], selectableCount: Int)
        case location(LocationPayload, isLive: Bool, sequence: Int64?)
        case contact(ContactPayload)
        case contacts([ContactPayload])
        case system(String)
    }
}

extension UIMessage {
    enum Status: Hashable, Sendable {
        case sent
        case delivered
        case read
        case played

        /// Monotone ordering for receipt-status resolution (higher wins).
        var sortOrder: Int {
            switch self {
            case .sent:      return 0
            case .delivered: return 1
            case .played:    return 2
            case .read:      return 3
            }
        }
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
                               localPath: b.media?.filePath,
                               waveform: b.media?.waveform.flatMap {
                                   Data(base64Encoded: $0)
                               },
                               isPTT: b.media?.isPTT ?? false)
            // F38: capture sender-side dimensions for placeholder
            // sizing. Drop zeros so the bubble can fall back to the
            // square default when the sender didn't ship them.
            if let w = b.media?.width, w > 0 { self.mediaWidth = w }
            if let h = b.media?.height, h > 0 { self.mediaHeight = h }
        case "poll":
            if let p = b.poll {
                self.body = .poll(question: p.question,
                                  options: p.options,
                                  selectableCount: p.selectableCount)
            } else {
                self.body = .system(b.kind)
            }
        case "location":
            if let loc = b.location {
                self.body = .location(
                    LocationPayload(lat: loc.lat, lng: loc.lng,
                                    name: loc.name, address: loc.address),
                    isLive: false, sequence: nil)
            } else {
                self.body = .system("(location)")
            }
        case "location_live":
            if let loc = b.location {
                self.body = .location(
                    LocationPayload(lat: loc.lat, lng: loc.lng,
                                    name: loc.name, address: loc.address),
                    isLive: true, sequence: b.locationSequence)
            } else {
                self.body = .system("(live location)")
            }
        case "contact":
            if let c = b.contact {
                self.body = .contact(ContactPayload.fromVCard(
                    c.vcard, displayName: c.displayName))
            } else {
                self.body = .system("(contact)")
            }
        case "contacts":
            if let arr = b.contactsArray {
                let cards = arr.contacts.map {
                    ContactPayload.fromVCard($0.vcard, displayName: $0.displayName)
                }
                self.body = .contacts(cards)
            } else {
                self.body = .system("(contacts)")
            }
        default:
            // F35: surface synthetic system text when present (the
            // bridge emits these for encryption-key changes +
            // disappearing-timer changes). Fall back to the bare kind
            // for true unknowns.
            if let t = b.text, !t.isEmpty {
                self.body = .system(t)
            } else {
                self.body = .system(b.kind)
            }
        }
        if let q = b.quoted {
            self.quotedMessageID = q.messageID
            self.quotedSenderJID = q.senderJID
            self.quotedFromMe = q.fromMe
            self.quotedTextSnippet = q.snippet
            self.quotedKind = q.kind
        }
        self.isForwarded = b.isForwarded ?? false
        self.isViewOnce = b.isViewOnce ?? false
    }
}
