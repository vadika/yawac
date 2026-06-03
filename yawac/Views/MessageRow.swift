import AppKit
import AVKit
import SwiftUI

/// One emoji + reactor list. Hover surfaces names via `.help`; click
/// opens a popover with the same list (richer affordance + works on
/// touch / a11y paths that ignore tooltips).
private struct ReactionChip: View {
    let emoji: String
    let senders: [String]
    let nameFor: (String) -> String
    @State private var showPopover: Bool = false

    private var names: [String] {
        senders.map(nameFor).filter { !$0.isEmpty }
    }

    private var tooltip: String {
        names.joined(separator: ", ")
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 2) {
                Text(emoji).font(.caption)
                if senders.count > 1 {
                    Text("\(senders.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.gray.opacity(0.15), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(emoji).font(.title3)
                    Text("Reacted").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.callout)
                }
            }
            .padding(10)
            .frame(minWidth: 140, alignment: .leading)
        }
    }
}

struct MessageRow: View {
    let message: UIMessage
    let status: UIMessage.Status?
    let senderName: String?
    let localPath: String?
    let reactions: [String]
    /// Senders grouped by emoji — used to surface names in tooltip/popover.
    let reactors: [String: [String]]
    let downloadError: String?
    let onRetryDownload: (() -> Void)?
    let voteCounts: [String: Int]
    let votersByOption: [String: [String]]
    let mySelections: Set<String>
    let onCastVote: (([String], [BridgePollOption]) -> Void)?
    let myReaction: String?
    let onReact: ((String) -> Void)?  // pass "" to clear our reaction
    let mentionResolver: (String) -> String
    let onOpenChat: ((String) -> Void)?
    let onReply: ((UIMessage) -> Void)?
    let onEdit: ((UIMessage) -> Void)?
    let onDeleteForEveryone: ((UIMessage) -> Void)?
    let onDeleteForMe: ((UIMessage) -> Void)?
    let onStar: ((UIMessage) -> Void)?
    let onPin: ((UIMessage) -> Void)?
    let onForward: ((UIMessage) -> Void)?
    let onJumpToQuoted: ((String) -> Void)?
    let isHighlighted: Bool
    let selecting: Bool
    let selected: Bool
    let selectable: Bool
    let onToggleSelect: (() -> Void)?
    var isFindHit: Bool = false
    var isFindCurrent: Bool = false

    @Environment(TranslationViewModel.self) private var translation

    @State private var mentionPopover: MentionTarget?
    @State private var showContextMenu: Bool = false
    @State private var contextMenuAnchor: UnitPoint = .center

    struct MentionTarget: Identifiable {
        let id = UUID()
        let jid: String
        let displayName: String
    }

    init(message: UIMessage, status: UIMessage.Status? = nil,
         senderName: String? = nil, localPath: String? = nil,
         reactions: [String] = [],
         reactors: [String: [String]] = [:],
         downloadError: String? = nil,
         onRetryDownload: (() -> Void)? = nil,
         voteCounts: [String: Int] = [:],
         votersByOption: [String: [String]] = [:],
         mySelections: Set<String> = [],
         onCastVote: (([String], [BridgePollOption]) -> Void)? = nil,
         myReaction: String? = nil,
         onReact: ((String) -> Void)? = nil,
         mentionResolver: @escaping (String) -> String = { $0 },
         onOpenChat: ((String) -> Void)? = nil,
         onReply: ((UIMessage) -> Void)? = nil,
         onEdit: ((UIMessage) -> Void)? = nil,
         onDeleteForEveryone: ((UIMessage) -> Void)? = nil,
         onDeleteForMe: ((UIMessage) -> Void)? = nil,
         onStar: ((UIMessage) -> Void)? = nil,
         onPin: ((UIMessage) -> Void)? = nil,
         onForward: ((UIMessage) -> Void)? = nil,
         onJumpToQuoted: ((String) -> Void)? = nil,
         isHighlighted: Bool = false,
         selecting: Bool = false,
         selected: Bool = false,
         selectable: Bool = true,
         onToggleSelect: (() -> Void)? = nil,
         isFindHit: Bool = false,
         isFindCurrent: Bool = false) {
        self.message = message
        self.status = status
        self.senderName = senderName
        self.localPath = localPath
        self.reactions = reactions
        self.reactors = reactors
        self.downloadError = downloadError
        self.onRetryDownload = onRetryDownload
        self.voteCounts = voteCounts
        self.votersByOption = votersByOption
        self.mySelections = mySelections
        self.onCastVote = onCastVote
        self.myReaction = myReaction
        self.onReact = onReact
        self.mentionResolver = mentionResolver
        self.onOpenChat = onOpenChat
        self.onReply = onReply
        self.onEdit = onEdit
        self.onDeleteForEveryone = onDeleteForEveryone
        self.onDeleteForMe = onDeleteForMe
        self.onStar = onStar
        self.onPin = onPin
        self.onForward = onForward
        self.onJumpToQuoted = onJumpToQuoted
        self.isHighlighted = isHighlighted
        self.selecting = selecting
        self.selected = selected
        self.selectable = selectable
        self.onToggleSelect = onToggleSelect
        self.isFindHit = isFindHit
        self.isFindCurrent = isFindCurrent
    }

    /// Returns true when the bubble should render the sender header
    /// (avatar + name). Applies to multi-poster chats: groups, broadcast
    /// lists, and the Status feed (`status@broadcast`).
    private var isGroupChat: Bool {
        let jid = message.chatJID
        return jid.hasSuffix("@g.us")
            || jid.hasSuffix("@broadcast")
            || jid == "status@broadcast"
    }

    private var senderDisplay: String {
        if let senderName, !senderName.isEmpty { return senderName }
        let raw = message.senderJID
        if let at = raw.firstIndex(of: "@") {
            return String(raw[..<at])
        }
        return raw
    }

    var body: some View {
        // Normal rendering is exactly `rowContent` (no extra wrapper) — a
        // flexible HStack + .contentShape around the Spacer-padded row sent
        // SwiftUI into an infinite layout-sizing cycle. The selection
        // wrapper only exists while forwarding.
        let tint: Color = isFindCurrent ? Theme.findHighlightCurrent
                         : isFindHit    ? Theme.findHighlight
                         : .clear
        return Group {
            if selecting {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .scaledIcon(18)
                        .foregroundStyle(selected ? Theme.accent : Theme.textFaint)
                        .opacity(selectable ? 1 : 0.3)
                    rowContent
                        .opacity(selectable ? 1 : 0.4)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { if selectable { onToggleSelect?() } }
            } else {
                rowContent
            }
        }
        .background(tint)
    }

    private var rowContent: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                    if !message.fromMe && isGroupChat {
                        senderHeader
                    }
                    bodyView
                    footerView
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    message.fromMe ? Theme.ownBubble : Theme.otherBubble,
                    in: .rect(cornerRadius: Theme.bubbleRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                        .stroke(message.fromMe ? Theme.ownBorder : Theme.otherBorder,
                                lineWidth: 1)
                )
                .foregroundStyle(message.fromMe ? Theme.ownText : Theme.otherText)
                .background(
                    isHighlighted
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear,
                    in: .rect(cornerRadius: Theme.bubbleRadius)
                )
                .animation(.easeOut(duration: 0.3), value: isHighlighted)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        guard message.revokedAt == nil,
                              !message.locallyDeleted,
                              !isSystemMessage
                        else { return }
                        if message.fromMe {
                            if MessageLifecycle.canEdit(message) {
                                onEdit?(message)
                            }
                        } else {
                            onReply?(message)
                        }
                    }
                )
                .overlay(
                    Group {
                        if !message.locallyDeleted, !isSystemMessage {
                            RightClickCatcher { point in
                                contextMenuAnchor = point
                                showContextMenu = true
                            }
                        }
                    }
                )
                .popover(isPresented: $showContextMenu,
                         attachmentAnchor: .point(contextMenuAnchor),
                         arrowEdge: .bottom) {
                    MessageContextMenu(
                        message: message,
                        canEdit: MessageLifecycle.canEdit(message),
                        canRevoke: MessageLifecycle.canRevoke(message),
                        onPickReaction: { emoji in onReact?(emoji) },
                        onReply: { onReply?(message) },
                        onForward: { onForward?(message) },
                        onCopyText: {
                            if case .text(let body) = message.body, !body.isEmpty {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(body, forType: .string)
                            }
                        },
                        onStar: { onStar?(message) },
                        onPin: { onPin?(message) },
                        onDeleteForMe: { onDeleteForMe?(message) },
                        onDeleteForEveryone: { onDeleteForEveryone?(message) },
                        onEdit: { onEdit?(message) },
                        dismiss: { showContextMenu = false }
                    )
                }
                .popover(item: $mentionPopover) { target in
                    mentionPopoverContent(target: target)
                }
                if !reactions.isEmpty, message.revokedAt == nil, !message.locallyDeleted {
                    reactionChips
                }
            }
            if !message.fromMe { Spacer(minLength: 60) }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "yawac", url.host == "mention" {
                let raw = url.path.hasPrefix("/")
                    ? String(url.path.dropFirst())
                    : url.path
                let jid = raw.removingPercentEncoding ?? raw
                let name = mentionResolver(jid)
                let display = (name.isEmpty || name == jid) ? fallbackDisplay(for: jid) : name
                mentionPopover = MentionTarget(jid: jid, displayName: display)
                return .handled
            }
            return .systemAction
        })
    }

    /// Sender avatar + name. Left-click switches to that contact's 1:1
    /// chat; right-click opens the same user menu as @mention popovers.
    @ViewBuilder
    private var senderHeader: some View {
        Button {
            onOpenChat?(message.senderJID)
        } label: {
            HStack(spacing: 6) {
                AvatarView(jid: message.senderJID, name: senderDisplay, size: 24)
                Text(senderDisplay)
                    .font(.caption).bold()
                    .foregroundStyle(.tint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Send message") {
                onOpenChat?(message.senderJID)
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(senderDisplay, forType: .string)
            }
            Button("Copy JID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.senderJID, forType: .string)
            }
        }
    }

    private func fallbackDisplay(for jid: String) -> String {
        if let at = jid.firstIndex(of: "@") {
            return String(jid[..<at])
        }
        return jid
    }

    @ViewBuilder
    private func mentionPopoverContent(target: MentionTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AvatarView(jid: target.jid, name: target.displayName, size: 40)
                VStack(alignment: .leading) {
                    Text(target.displayName).font(.headline)
                    Text(target.jid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Divider()
            Button {
                onOpenChat?(target.jid)
                mentionPopover = nil
            } label: {
                Label("Send message", systemImage: "message")
            }
            .buttonStyle(.borderless)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.displayName, forType: .string)
                mentionPopover = nil
            } label: {
                Label("Copy name", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.jid, forType: .string)
                mentionPopover = nil
            } label: {
                Label("Copy JID", systemImage: "doc.on.doc.fill")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    private var isSystemMessage: Bool {
        if case .system = message.body { return true }
        return false
    }

    /// A stable per-message prefix that flips when the message is edited,
    /// so the in-memory translation cache is invalidated on edit.
    private var translationSurfacePrefix: String {
        if let ts = message.editedAt {
            return "\(message.id)#\(Int64(ts.timeIntervalSince1970))"
        }
        return message.id
    }

    @ViewBuilder
    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(reactions)), id: \.self) { emoji in
                ReactionChip(
                    emoji: emoji,
                    senders: reactors[emoji] ?? [],
                    nameFor: { jid in
                        jid == "me" ? "You" : mentionResolver(jid)
                    })
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        if message.revokedAt != nil {
            tombstoneText(message.fromMe ? "You deleted this message"
                                         : "This message was deleted")
        } else if message.locallyDeleted {
            tombstoneText("You deleted this for yourself")
        } else {
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                if message.isForwarded {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .scaledIcon(10)
                        Text("Forwarded")
                            .scaledUI(11)
                            .italic()
                    }
                    .foregroundStyle(Theme.textFaint)
                }
                if message.quotedMessageID != nil {
                    quotedStrip
                }
                existingBodyContent
            }
        }
    }

    @ViewBuilder
    private var existingBodyContent: some View {
        switch message.body {
        case .text(let s):
            translatableText(surfaceID: "\(translationSurfacePrefix):text", raw: s)
        case .media(let kind, let caption, let fileName, let path):
            mediaView(kind: kind, caption: caption, fileName: fileName, path: path)
        case .poll(let q, let options, let selectable):
            pollView(question: q, options: options, selectableCount: selectable)
        case .system(let s):
            Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tombstoneText(_ s: String) -> some View {
        Text(s)
            .italic()
            .scaledUI(12.5)
            .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder
    private var quotedStrip: some View {
        Button {
            if let id = message.quotedMessageID {
                onJumpToQuoted?(id)
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quotedSenderDisplay)
                        .scaledUI(11, weight: .semibold)
                        .foregroundStyle(Theme.text)
                    Text(message.quotedTextSnippet ?? "")
                        .scaledUI(11)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Theme.surfaceAlt, in: .rect(cornerRadius: 4))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(onJumpToQuoted == nil)
    }

    private var quotedSenderDisplay: String {
        if message.quotedFromMe { return "You" }
        let jid = message.quotedSenderJID ?? ""
        let resolved = mentionResolver(jid)
        if !resolved.isEmpty, resolved != jid { return resolved }
        if let at = jid.firstIndex(of: "@") {
            return String(jid[..<at])
        }
        return jid
    }

    @ViewBuilder
    private func pollView(question: String,
                          options: [BridgePollOption],
                          selectableCount: Int) -> some View {
        let totalVotes = voteCounts.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            translatableText(surfaceID: "\(translationSurfacePrefix):poll-q",
                             raw: question,
                             baseStyle: .pollQuestion)
            ForEach(Array(options.enumerated()), id: \.element.hash) { idx, opt in
                let count = voteCounts[opt.hash] ?? 0
                let picked = mySelections.contains(opt.hash)
                let voterNames = (votersByOption[opt.hash] ?? [])
                    .map { mentionResolver($0) }
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        // Multi-select polls (selectable == 0 OR > 1) submit
                        // the full picked-set on each tap (WhatsApp wire
                        // semantics: every PollUpdate replaces the prior).
                        // Single-select polls just send the tapped hash.
                        let multi = selectableCount == 0 || selectableCount > 1
                        if multi {
                            var next = mySelections
                            if picked { next.remove(opt.hash) } else { next.insert(opt.hash) }
                            onCastVote?(Array(next), options)
                        } else {
                            onCastVote?([opt.hash], options)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: pollIconName(selectable: selectableCount, picked: picked))
                                .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                            translatableText(surfaceID: "\(translationSurfacePrefix):poll-opt-\(idx)",
                                             raw: opt.name,
                                             baseStyle: .pollOption)
                                .fontWeight(picked ? .semibold : .regular)
                            Spacer(minLength: 8)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(onCastVote == nil)
                    if !voterNames.isEmpty {
                        Text(voterNames.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 24)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                Text((selectableCount == 0 || selectableCount > 1) ? "Multiple choices" : "Single choice")
                if totalVotes > 0 {
                    Text("·")
                    Text("\(totalVotes) vote\(totalVotes == 1 ? "" : "s")")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    /// Returns an `AttributedString` with @mentions styled bold + tinted and
    /// any URLs auto-linked.
    private func richText(from raw: String) -> AttributedString {
        let (rewritten, mentions) = resolveMentions(in: raw)
        var attr = AttributedString(rewritten)
        // Style mentions: bold, tint colour, custom URL scheme so taps fire.
        for entry in mentions {
            if let r = attr.range(of: entry.replacement) {
                attr[r].font = .body.bold()
                attr[r].foregroundColor = .accentColor
                let encoded = entry.jid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.jid
                if let url = URL(string: "yawac://mention/\(encoded)") {
                    attr[r].link = url
                }
            }
        }
        // Auto-link any plain URLs in the (possibly-rewritten) text.
        let str = String(attr.characters)
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsRange = NSRange(str.startIndex..<str.endIndex, in: str)
        detector?.enumerateMatches(in: str, range: nsRange) { match, _, _ in
            guard let match, let url = match.url,
                  let range = Range(match.range, in: str),
                  let attrRange = attr.range(of: String(str[range])) else { return }
            // Don't clobber mention styling.
            if attr[attrRange].link != nil { return }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = .accentColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }

    /// Renders a piece of translatable text with an optional Translate /
    /// See original footer link. `surfaceID` must be unique per surface
    /// per message so multiple translatable pieces (text, caption, poll
    /// question, options) can be independently toggled.
    @ViewBuilder
    private func translatableText(surfaceID: String,
                                  raw: String,
                                  baseStyle: TranslatableStyle = .body) -> some View {
        let offer = translation.shouldOfferTranslate(text: raw)
        let entry = translation.store.entry(for: surfaceID)
        let inFlight = translation.store.inFlight.contains(surfaceID)
        let displayed: String = {
            if let entry, entry.showingTranslated {
                return entry.translated
            }
            return raw
        }()
        VStack(alignment: .leading, spacing: 2) {
            switch baseStyle {
            case .body:
                Text(richText(from: displayed))
                    .scaledUI(13)
                    .textSelection(.enabled)
            case .caption:
                Text(displayed)
                    .scaledUI(12)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .pollQuestion:
                Text(displayed)
                    .scaledUI(13, weight: .semibold)
            case .pollOption:
                Text(displayed)
                    .scaledUI(12.5)
            }
            if offer.offer || entry != nil {
                Button {
                    Task {
                        await translation.translate(
                            surfaceID: surfaceID,
                            text: raw,
                            source: offer.lang
                                ?? entry?.sourceLang
                                ?? "auto")
                    }
                } label: {
                    Text(footerLabel(entry: entry, inFlight: inFlight))
                        .scaledUI(11)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(inFlight)
            }
        }
    }

    private func footerLabel(entry: TranslationStore.Entry?,
                             inFlight: Bool) -> String {
        if inFlight { return "Translating…" }
        guard let entry else { return "Translate" }
        return entry.showingTranslated ? "See original" : "Show translation"
    }

    enum TranslatableStyle {
        case body, caption, pollQuestion, pollOption
    }

    /// Rewrites `@<digits>` to `@<display name>` and returns both the new
    /// string + each mention's literal replacement substring paired with the
    /// JID it should resolve to when tapped.
    private func resolveMentions(in s: String)
        -> (String, [(replacement: String, jid: String)]) {
        guard s.contains("@"),
              let regex = try? NSRegularExpression(pattern: "@(\\d{5,})") else {
            return (s, [])
        }
        var out = s
        var styled: [(replacement: String, jid: String)] = []
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s))
        for m in matches.reversed() {
            guard m.numberOfRanges >= 2,
                  let full = Range(m.range, in: out),
                  let digits = Range(m.range(at: 1), in: out) else { continue }
            let phone = String(out[digits])
            let candidates = ["\(phone)@s.whatsapp.net", "\(phone)@lid"]
            var replacement = "@\(phone)"
            var resolvedJID = phone
            for jid in candidates {
                let name = mentionResolver(jid)
                if name != phone, !name.isEmpty {
                    replacement = "@\(name)"
                    resolvedJID = jid
                    break
                }
            }
            out.replaceSubrange(full, with: replacement)
            styled.append((replacement: replacement, jid: resolvedJID))
        }
        return (out, styled)
    }

    @ViewBuilder
    private var footerView: some View {
        HStack(spacing: 5) {
            Text(message.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                .scaledMono(10.5)
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
            if message.editedAt != nil {
                Text("· edited")
                    .scaledMono(10.5)
                    .foregroundStyle(Theme.textFaint)
                    .help("Edited \(message.editedAt!.formatted(.relative(presentation: .named)))")
            }
            if message.starredAt != nil {
                Image(systemName: "star.fill")
                    .scaledIcon(10, weight: .medium)
                    .foregroundStyle(.yellow)
                    .help("Starred")
            }
            if message.pinnedAt != nil {
                Image(systemName: "pin.fill")
                    .scaledIcon(9.5, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(35))
                    .help("Pinned")
            }
            if message.fromMe, let status {
                Image(systemName: statusIcon(status))
                    .scaledIcon(11, weight: .medium)
                    .foregroundStyle(statusColor(status))
            }
        }
    }

    @ViewBuilder
    private func mediaView(kind: String, caption: String?, fileName: String?, path: String?) -> some View {
        let effectivePath = localPath ?? path
        VStack(alignment: .leading, spacing: 4) {
            switch kind {
            case "image":
                imageBubble(path: effectivePath)
            case "sticker":
                stickerBubble(path: effectivePath)
            case "video":
                videoBubble(path: effectivePath)
            case "audio":
                audioBubble(path: effectivePath)
            case "document":
                documentBubble(path: effectivePath, fileName: fileName)
            default:
                Label(kind, systemImage: iconName(for: kind))
                    .foregroundStyle(.secondary)
            }
            if let caption, !caption.isEmpty {
                translatableText(surfaceID: "\(translationSurfacePrefix):caption",
                                 raw: caption,
                                 baseStyle: .caption)
            }
        }
    }

    @ViewBuilder
    private func imageBubble(path: String?) -> some View {
        if let p = path, let img = NSImage(contentsOfFile: p) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                }
        } else {
            downloadingPlaceholder("photo")
        }
    }

    @ViewBuilder
    private func stickerBubble(path: String?) -> some View {
        if let p = path, let img = NSImage(contentsOfFile: p) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160, maxHeight: 160)
        } else {
            downloadingPlaceholder("face.smiling")
        }
    }

    @ViewBuilder
    private func videoBubble(path: String?) -> some View {
        if let p = path {
            VideoThumbnailView(path: p)
                .frame(maxWidth: 320, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 8))
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                }
        } else {
            downloadingPlaceholder("play.rectangle")
        }
    }

    @ViewBuilder
    private func audioBubble(path: String?) -> some View {
        if let p = path {
            AudioPlayerView(path: p)
        } else {
            downloadingPlaceholder("waveform")
        }
    }

    @ViewBuilder
    private func documentBubble(path: String?, fileName: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: downloadError != nil ? "exclamationmark.triangle.fill" : "doc")
                .font(.title2)
                .foregroundStyle(downloadError != nil ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName ?? "Document").font(.callout).bold()
                if path != nil {
                    Text("Tap to open").font(.caption2).foregroundStyle(.secondary)
                } else if let err = downloadError {
                    Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if path == nil, downloadError != nil, let retry = onRetryDownload {
                Spacer()
                Button("Retry", action: retry).buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(6)
        .frame(maxWidth: 320, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture {
            if let p = path {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            }
        }
    }

    @ViewBuilder
    private func downloadingPlaceholder(_ icon: String) -> some View {
        if let err = downloadError {
            let expired = err == "media expired"
            HStack(spacing: 6) {
                Image(systemName: expired ? "clock.badge.xmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(expired ? Theme.textFaint : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(expired ? "Media no longer available" : "Download failed")
                        .font(.caption)
                        .foregroundStyle(expired ? Theme.textMuted : Theme.text)
                    if !expired {
                        Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if let retry = onRetryDownload {
                    Button(expired ? "Refetch" : "Retry", action: retry)
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pollIconName(selectable: Int, picked: Bool) -> String {
        // selectable == 0 is WhatsApp's wire encoding for "unlimited" (multi);
        // > 1 is "pick up to N" (also multi); 1 is single.
        let multi = selectable == 0 || selectable > 1
        switch (multi, picked) {
        case (true, true):   return "checkmark.square.fill"
        case (true, false):  return "square"
        case (false, true):  return "largecircle.fill.circle"
        case (false, false): return "circle"
        }
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "image":    return "photo"
        case "audio":    return "waveform"
        case "video":    return "play.rectangle"
        case "sticker":  return "face.smiling"
        default:         return "doc"
        }
    }

    private func statusIcon(_ s: UIMessage.Status) -> String {
        switch s {
        case .sent:      return "checkmark"
        case .delivered: return "checkmark.circle"
        case .read:      return "checkmark.circle.fill"
        case .played:    return "play.circle.fill"
        }
    }

    private func statusColor(_ s: UIMessage.Status) -> Color {
        s == .read || s == .played ? Theme.accent : Theme.textFaint
    }
}
