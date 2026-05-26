import SwiftUI
import AppKit

struct ChatInfoView: View {
    let chatJID: String
    /// Called when the user clicks the inspector's X. Toggled into the
    /// parent's @State so the inspector binding closes — using
    /// `@Environment(\.dismiss)` here would close the enclosing window
    /// instead of the inspector (the inspector content shares the
    /// window's dismiss environment).
    var onClose: (() -> Void)? = nil
    @Environment(SessionViewModel.self) private var session
    @State private var group: BridgeGroupModel?
    @State private var loadingGroup = false
    @State private var loadError: String?
    @State private var linkedGroups: [BridgeGroupModel] = []
    @State private var userAbout: String?
    @State private var loadingUserInfo = false

    private var isGroup: Bool { chatJID.hasSuffix("@g.us") }
    private var name: String { session.displayName(for: chatJID) }

    var body: some View {
        VStack(spacing: 0) {
            // ─── Title-bar gutter. 64pt matches the chat header so the
            // inspector seam aligns with the conversation pane's seam.
            eyebrow
                .padding(.horizontal, 18)
                .frame(height: 64)
                .background(Theme.sidebarBg)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    jidRow
                    if isGroup {
                        if loadingGroup {
                            ProgressView().controlSize(.small).tint(Theme.accent)
                                .frame(maxWidth: .infinity)
                        }
                        if let err = loadError {
                            Text(err).font(Theme.ui(12))
                                .foregroundStyle(Color.red.opacity(0.85))
                        }
                        if let g = group { groupBody(g) }
                    } else {
                        userBody
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        }
        .background(Theme.sidebarBg)
        .frame(minWidth: 300)
        .ignoresSafeArea(.container, edges: .top)
        .task(id: chatJID) {
            if isGroup {
                await loadGroup()
            } else {
                await loadUserInfo()
            }
        }
    }

    // ─── Eyebrow ─────────────────────────────────────────────────────
    @ViewBuilder
    private var eyebrow: some View {
        HStack {
            Text((isGroup ? "GROUP INFO" : "USER INFO"))
                .font(Theme.ui(10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textFaint)
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    // ─── Hero (avatar + name + subline) ──────────────────────────────
    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 10) {
            AvatarView(jid: chatJID, name: name, size: 92)
            VStack(spacing: 4) {
                Text(name)
                    .font(Theme.ui(20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                if isGroup, let g = group {
                    Text("GROUP · \(g.participants.count) MEMBERS")
                        .font(Theme.ui(10.5, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(Theme.textMuted)
                } else if !isGroup {
                    if let about = userAbout, !about.isEmpty {
                        Text(about)
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    } else if loadingUserInfo {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // ─── JID row with copy ───────────────────────────────────────────
    @ViewBuilder
    private var jidRow: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chatJID, forType: .string)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Text(chatJID)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy JID")
    }

    // ─── User body (1:1) ─────────────────────────────────────────────
    @ViewBuilder
    private var userBody: some View {
        if let pushName = session.contactNames[chatJID] {
            metadataRow([
                .init(label: "PUSH NAME", value: pushName),
                .init(label: "TYPE", value: "Direct chat"),
            ])
        } else {
            metadataRow([
                .init(label: "TYPE", value: "Direct chat"),
            ])
        }
        actionRow(actions: [
            .init(label: "Mute", icon: "speaker.slash"),
            .init(label: "Search", icon: "magnifyingglass"),
            .init(label: "Block", icon: "hand.raised", destructive: true),
        ])
    }

    @MainActor
    private func loadUserInfo() async {
        guard let client = session.client else { return }
        userAbout = nil
        loadingUserInfo = true
        defer { loadingUserInfo = false }
        let info = try? client.getUserInfo(jid: chatJID)
        userAbout = info?.status
    }

    // ─── Group body ──────────────────────────────────────────────────
    @ViewBuilder
    private func groupBody(_ g: BridgeGroupModel) -> some View {
        if !g.topic.isEmpty {
            sectionCard(label: "TOPIC") {
                Text(g.topic)
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
        }

        metadataRow([
            .init(label: "MEMBERS", value: "\(g.participants.count)"),
            .init(label: "CREATED",
                  value: Date(timeIntervalSince1970: TimeInterval(g.created))
                    .formatted(.dateTime.day().month(.abbreviated).year())),
        ])

        actionRow(actions: [
            .init(label: "Mute", icon: "speaker.slash"),
            .init(label: "Search", icon: "magnifyingglass"),
            .init(label: "Leave", icon: "rectangle.portrait.and.arrow.right",
                  destructive: true),
        ])

        sectionLabel("PARTICIPANTS", trailing: "\(g.participants.count)")
        VStack(spacing: 0) {
            ForEach(sortedParticipants(g.participants), id: \.jid) { p in
                participantRow(p)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }

        if g.isParent && !linkedGroups.isEmpty {
            sectionLabel("LINKED GROUPS", trailing: "\(linkedGroups.count)")
            VStack(spacing: 0) {
                ForEach(linkedGroups, id: \.jid) { sub in
                    linkedGroupRow(sub)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }

    // ─── Reusable bits ───────────────────────────────────────────────
    private struct MetaItem { let label: String; let value: String }
    @ViewBuilder
    private func metadataRow(_ items: [MetaItem]) -> some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(items[i].label)
                        .font(Theme.ui(9.5, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.textFaint)
                    Text(items[i].value)
                        .font(Theme.ui(14, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
        }
    }

    private struct ActionItem {
        let label: String
        let icon: String
        var destructive: Bool = false
    }
    @ViewBuilder
    private func actionRow(actions: [ActionItem]) -> some View {
        HStack(spacing: 8) {
            ForEach(actions.indices, id: \.self) { i in
                let a = actions[i]
                VStack(spacing: 6) {
                    Image(systemName: a.icon)
                        .font(.system(size: 14, weight: .regular))
                    Text(a.label)
                        .font(Theme.ui(11.5, weight: .medium))
                }
                .foregroundStyle(a.destructive ? Color.red.opacity(0.95) : Theme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func sectionCard<C: View>(label: String,
                                      @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.ui(9.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.textFaint)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.ui(10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textFaint)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func participantRow(_ p: BridgeParticipantModel) -> some View {
        Button {
            let jid = p.jid
            Task { @MainActor in
                session.requestSelectChat(jid)
            }
        } label: {
            HStack(spacing: 10) {
                AvatarView(jid: p.jid, name: session.displayName(for: p.jid), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayName(for: p.jid))
                            .font(Theme.ui(13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if p.isSuper {
                            roleBadge("SUPER", color: Theme.superRole)
                        } else if p.isAdmin {
                            roleBadge("ADMIN", color: Theme.adminRole)
                        }
                    }
                    Text(p.jid)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy JID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.jid, forType: .string)
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.displayName(for: p.jid),
                                               forType: .string)
            }
        }
    }

    @ViewBuilder
    private func roleBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.ui(9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }

    @ViewBuilder
    private func linkedGroupRow(_ sub: BridgeGroupModel) -> some View {
        Button {
            session.requestSelectChat(sub.jid)
        } label: {
            HStack(spacing: 10) {
                AvatarView(jid: sub.jid,
                           name: sub.name.isEmpty
                               ? session.displayName(for: sub.jid)
                               : sub.name,
                           size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.name.isEmpty
                         ? session.displayName(for: sub.jid)
                         : sub.name)
                        .font(Theme.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(sub.jid)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sortedParticipants(_ ps: [BridgeParticipantModel])
        -> [BridgeParticipantModel] {
        ps.sorted { lhs, rhs in
            let lt = (lhs.isSuper ? 2 : (lhs.isAdmin ? 1 : 0))
            let rt = (rhs.isSuper ? 2 : (rhs.isAdmin ? 1 : 0))
            if lt != rt { return lt > rt }
            return session.displayName(for: lhs.jid)
                .localizedCaseInsensitiveCompare(session.displayName(for: rhs.jid))
                == .orderedAscending
        }
    }

    @MainActor
    private func loadGroup() async {
        guard let client = session.client else { return }
        loadingGroup = true
        defer { loadingGroup = false }
        do {
            let g = try client.getGroupInfo(jid: chatJID)
            self.group = g
            if g.isParent {
                if let all = try? client.listGroups() {
                    self.linkedGroups = all.filter { $0.linkedParentJID == chatJID }
                }
            }
        } catch {
            self.loadError = error.localizedDescription
        }
    }
}
