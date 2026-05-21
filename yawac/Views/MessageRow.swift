import AppKit
import AVKit
import SwiftUI

struct MessageRow: View {
    let message: UIMessage
    let status: UIMessage.Status?
    let senderName: String?
    let localPath: String?
    let reactions: [String]
    let downloadError: String?
    let onRetryDownload: (() -> Void)?
    let voteCounts: [String: Int]
    let mySelections: Set<String>
    let onCastVote: (([String], [BridgePollOption]) -> Void)?
    let myReaction: String?
    let onReact: ((String) -> Void)?  // pass "" to clear our reaction
    let mentionResolver: (String) -> String
    let onOpenChat: ((String) -> Void)?

    @State private var mentionPopover: MentionTarget?

    struct MentionTarget: Identifiable {
        let id = UUID()
        let jid: String
        let displayName: String
    }

    init(message: UIMessage, status: UIMessage.Status? = nil,
         senderName: String? = nil, localPath: String? = nil,
         reactions: [String] = [],
         downloadError: String? = nil,
         onRetryDownload: (() -> Void)? = nil,
         voteCounts: [String: Int] = [:],
         mySelections: Set<String> = [],
         onCastVote: (([String], [BridgePollOption]) -> Void)? = nil,
         myReaction: String? = nil,
         onReact: ((String) -> Void)? = nil,
         mentionResolver: @escaping (String) -> String = { $0 },
         onOpenChat: ((String) -> Void)? = nil) {
        self.message = message
        self.status = status
        self.senderName = senderName
        self.localPath = localPath
        self.reactions = reactions
        self.downloadError = downloadError
        self.onRetryDownload = onRetryDownload
        self.voteCounts = voteCounts
        self.mySelections = mySelections
        self.onCastVote = onCastVote
        self.myReaction = myReaction
        self.onReact = onReact
        self.mentionResolver = mentionResolver
        self.onOpenChat = onOpenChat
    }

    private static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

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
                .padding(8)
                .background(
                    message.fromMe
                        ? Color.accentColor.opacity(0.2)
                        : Color.gray.opacity(0.15),
                    in: .rect(cornerRadius: 10))
                .contextMenu { reactionMenu }
                .popover(item: $mentionPopover) { target in
                    mentionPopoverContent(target: target)
                }
                if !reactions.isEmpty {
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

    @ViewBuilder
    private var reactionMenu: some View {
        if let onReact, !isSystemBody {
            Section("React") {
                ForEach(Self.quickReactions, id: \.self) { e in
                    Button(myReaction == e ? "\(e) (clear)" : e) {
                        // Tapping the active emoji clears; tapping a new one
                        // replaces (WhatsApp allows one reaction per user).
                        onReact(myReaction == e ? "" : e)
                    }
                }
            }
        }
    }

    private var isSystemBody: Bool {
        if case .system = message.body { return true }
        return false
    }

    @ViewBuilder
    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(reactions)), id: \.self) { emoji in
                let count = reactions.filter { $0 == emoji }.count
                HStack(spacing: 2) {
                    Text(emoji).font(.caption)
                    if count > 1 {
                        Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.gray.opacity(0.15), in: .capsule)
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch message.body {
        case .text(let s):
            Text(richText(from: s)).textSelection(.enabled)
        case .media(let kind, let caption, let fileName, let path):
            mediaView(kind: kind, caption: caption, fileName: fileName, path: path)
        case .poll(let q, let options, let selectable):
            pollView(question: q, options: options, selectableCount: selectable)
        case .system(let s):
            Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pollView(question: String,
                          options: [BridgePollOption],
                          selectableCount: Int) -> some View {
        let totalVotes = voteCounts.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            Text(question).font(.callout).bold()
            ForEach(options, id: \.hash) { opt in
                let count = voteCounts[opt.hash] ?? 0
                let picked = mySelections.contains(opt.hash)
                Button {
                    onCastVote?([opt.hash], options)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pollIconName(selectable: selectableCount, picked: picked))
                            .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                        Text(opt.name)
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
                .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                Text(selectableCount > 1 ? "Multiple choices" : "Single choice")
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
        HStack(spacing: 4) {
            Text(message.timestamp, style: .time)
            if message.fromMe, let status {
                Image(systemName: statusIcon(status))
                    .foregroundStyle(statusColor(status))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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
                Text(richText(from: caption)).textSelection(.enabled)
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
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download failed").font(.caption)
                    Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let retry = onRetryDownload {
                    Button("Retry", action: retry).buttonStyle(.borderless).font(.caption)
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
        let multi = selectable > 1
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
        s == .read || s == .played ? .blue : .secondary
    }
}
