import SwiftUI
import AppKit

struct ChatInfoView: View {
    let chatJID: String
    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var group: BridgeGroupModel?
    @State private var loadingGroup = false
    @State private var loadError: String?
    @State private var linkedGroups: [BridgeGroupModel] = []

    private var isGroup: Bool { chatJID.hasSuffix("@g.us") }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if isGroup {
                    groupBody
                } else {
                    userBody
                }
            }
            .padding()
        }
        .frame(minWidth: 280)
        .task(id: chatJID) {
            guard isGroup else { return }
            await loadGroup()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            AvatarView(jid: chatJID, name: session.displayName(for: chatJID), size: 96)
            Text(session.displayName(for: chatJID))
                .font(.title2).bold()
            Text(chatJID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chatJID, forType: .string)
            } label: {
                Label("Copy JID", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var userBody: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            if let pushName = session.contactNames[chatJID] {
                LabeledContent("Push name", value: pushName)
            }
            LabeledContent("Type", value: "Direct chat")
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var groupBody: some View {
        Divider()
        if loadingGroup {
            ProgressView().controlSize(.small)
        }
        if let err = loadError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
        if let g = group {
            VStack(alignment: .leading, spacing: 6) {
                if !g.topic.isEmpty {
                    Text("Topic").font(.caption).foregroundStyle(.secondary)
                    Text(g.topic).textSelection(.enabled)
                }
                LabeledContent("Members", value: "\(g.participants.count)")
                LabeledContent("Created",
                               value: Date(timeIntervalSince1970: TimeInterval(g.created))
                                .formatted(date: .abbreviated, time: .shortened))
                if g.isParent {
                    LabeledContent("Type", value: "Community parent")
                } else if let parent = g.linkedParentJID, !parent.isEmpty {
                    LabeledContent("Type",
                                   value: "Sub-group of \(session.displayName(for: parent))")
                }
            }
            .padding(.horizontal, 4)

            Divider()
            Text("Participants").font(.headline)
            ForEach(sortedParticipants(g.participants), id: \.jid) { p in
                participantRow(p)
            }

            if g.isParent && !linkedGroups.isEmpty {
                Divider()
                Text("Linked groups").font(.headline)
                ForEach(linkedGroups, id: \.jid) { sub in
                    HStack(spacing: 8) {
                        AvatarView(jid: sub.jid, name: sub.name, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(sub.name.isEmpty
                                 ? session.displayName(for: sub.jid)
                                 : sub.name)
                                .font(.callout)
                            Text(sub.jid)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            session.requestSelectChat(sub.jid)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Open chat")
                    }
                }
            }
        }
    }

    private func participantRow(_ p: BridgeParticipantModel) -> some View {
        Button {
            session.requestSelectChat(p.jid)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                AvatarView(jid: p.jid, name: session.displayName(for: p.jid), size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.displayName(for: p.jid))
                        .font(.callout)
                    Text(p.jid)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if p.isSuper {
                    Text("super").font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.purple.opacity(0.2), in: .capsule)
                } else if p.isAdmin {
                    Text("admin").font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.blue.opacity(0.2), in: .capsule)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy JID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.jid, forType: .string)
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.displayName(for: p.jid), forType: .string)
            }
        }
    }

    private func sortedParticipants(_ ps: [BridgeParticipantModel])
        -> [BridgeParticipantModel] {
        ps.sorted { lhs, rhs in
            // Super > admin > member; within tier sort by name.
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
                // Populate linked sub-groups from the cached joined-groups
                // list. Cheap (no extra server roundtrips per child).
                if let all = try? client.listGroups() {
                    self.linkedGroups = all.filter { $0.linkedParentJID == chatJID }
                }
            }
        } catch {
            self.loadError = error.localizedDescription
        }
    }
}
