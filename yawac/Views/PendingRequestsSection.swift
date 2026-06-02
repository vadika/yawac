import SwiftUI

/// In-info admin queue for a group with approval-mode on. Rendered
/// inside `ChatInfoView.groupBody` between the participants list and
/// the leave-group action, and only when the current user admins the
/// group and the queue has at least one row. Bulk "Approve all" shows
/// only when more than one request is pending — single-row queues are
/// already one click away from the per-row check.
struct PendingRequestsSection: View {
    @Bindable var model: PendingRequestsSectionModel
    /// Resolves a JID to a human-readable display name. Injected so the
    /// row view can stay free of the SessionViewModel environment and
    /// remain trivially previewable.
    let displayName: (String) -> String

    /// Single shared formatter so we don't burn one per row on each
    /// re-render. `.short` keeps the strings inside the row's cramped
    /// secondary line (e.g. "5m ago", "2h ago").
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init(model: PendingRequestsSectionModel,
         displayName: @escaping (String) -> String) {
        self.model = model
        self.displayName = displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let err = model.error {
                Text(err)
                    .scaledUI(11)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.bottom, 2)
            }
            VStack(spacing: 0) {
                ForEach(model.requests) { row in
                    rowView(row)
                    if row.id != model.requests.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text("PENDING REQUESTS")
                .scaledUI(10, weight: .semibold)
                .tracking(1.2)
                .foregroundStyle(Theme.textFaint)
            Text("\(model.requests.count)")
                .scaledMono(10.5)
                .foregroundStyle(Theme.textFaint)
                .monospacedDigit()
            Spacer()
            if model.requests.count > 1 {
                Button {
                    Task { await model.approveAll() }
                } label: {
                    if model.bulkInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Approve all \(model.requests.count)")
                            .scaledUI(11, weight: .medium)
                            .foregroundStyle(Theme.accentText)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.bulkInFlight)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rowView(_ row: PendingRequestRow) -> some View {
        let inFlight = model.inFlightJIDs.contains(row.jid) || model.bulkInFlight
        HStack(spacing: 10) {
            AvatarView(jid: row.jid, name: displayName(row.jid), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(row.jid))
                    .scaledUI(13, weight: .medium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("requested " + Self.relativeFormatter.localizedString(
                    for: Date(timeIntervalSince1970: TimeInterval(row.requestedAt)),
                    relativeTo: Date()))
                    .scaledUI(11)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                if let code = row.failureCode {
                    Text("Couldn't apply (code \(code))")
                        .scaledUI(10.5)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineLimit(1)
                }
            }
            Spacer()
            if inFlight {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.approve(jid: row.jid) }
                } label: {
                    Image(systemName: "checkmark")
                        .scaledIcon(11, weight: .semibold)
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 26, height: 26)
                        .background(Theme.accentSoft, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Approve")
                Button {
                    Task { await model.reject(jid: row.jid) }
                } label: {
                    Image(systemName: "xmark")
                        .scaledIcon(11, weight: .semibold)
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 26, height: 26)
                        .background(Theme.surface, in: Circle())
                        .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Reject")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
