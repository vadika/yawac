import SwiftUI
import SQLite3
import AppKit

/// Settings → Diagnostics. Read-only inspector for stability / debt
/// work. Nothing here mutates app state — every section is a probe.
/// Hand-rolled SQLite queries against the SwiftData store run on
/// `.onAppear` so the per-render path stays free of fetches.
struct DiagnosticsPanel: View {
    @Environment(SessionViewModel.self) private var session

    @State private var probeInput: String = ""
    @State private var indexStatus: [(name: String, present: Bool)] = []
    @State private var historyStats: HistoryStats?
    @State private var callCountsCache: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            toolbarSection
            syncStateSection
            jidLookupSection
            indicesSection
            historySection
            bridgeCallCountsSection
        }
        .onAppear { refreshAll() }
    }

    // MARK: - Toolbar (global actions)

    /// F66: single top-of-panel control strip replacing per-section
    /// refresh/reset buttons. Refresh re-runs every probe, Reset clears
    /// the bridge call counters (the only mutable surface), Copy as JSON
    /// dumps every section's current state to the clipboard for paste-
    /// into-bug-report. Saves the user from clicking refresh on every
    /// card.
    private var toolbarSection: some View {
        SettingsCard {
            SettingsRow(label: "Actions") {
                HStack(spacing: 8) {
                    SettingsPillButton("Refresh all", style: .neutral) {
                        refreshAll()
                    }
                    SettingsPillButton("Reset counters", style: .neutral) {
                        session.client?.resetCallCounts()
                        refreshCallCounts()
                    }
                    SettingsPillButton("Copy as JSON", style: .neutral) {
                        copyAsJSON()
                    }
                }
            }
        }
    }

    private func refreshAll() {
        computeIndexStatus()
        computeHistoryStats()
        refreshCallCounts()
    }

    private func copyAsJSON() {
        var root: [String: Any] = [:]
        root["sync_state"] = [
            "full_sync_in_flight": session.fullSync.inFlight,
            "attempted_this_session": session.fullSync.attempted,
            "progress_pct": session.fullSync.progress,
            "chunks_landed": session.fullSync.chunks,
            "fresh_messages": session.fullSync.fresh,
            "dupe_messages": session.fullSync.dupe,
            "history_backfill_completed": UserDefaults.standard.bool(forKey: "historyBackfillCompleted"),
            "connection": connectionLabel(session.connection),
            "syncing_banner": session.syncing,
        ]
        root["indices"] = indexStatus.map {
            ["name": $0.name, "present": $0.present]
        }
        if let s = historyStats {
            root["history_stats"] = [
                "total_messages": s.totalMessages,
                "distinct_chats": s.distinctChats,
                "oldest": s.oldestMacEpoch.map { formatTimestamp($0) } ?? "—",
                "newest": s.newestMacEpoch.map { formatTimestamp($0) } ?? "—",
                "distinct_senders": s.distinctSenders,
                "senders_with_push_name": s.sendersWithPushName,
                "push_name_coverage_pct": pushCoverageLabel(s),
            ]
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var bridgeBlock: [String: Any] = [
            "snapshot_at": iso.string(from: Date()),
            "counts": callCountsCache,
        ]
        if let started = session.client?.callCountsStartedAt() {
            bridgeBlock["window_started_at"] = iso.string(from: started)
            bridgeBlock["window_seconds"] = Int(Date().timeIntervalSince(started))
        }
        root["bridge_calls"] = bridgeBlock
        guard let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    // MARK: - Sync state

    private var syncStateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Sync state")
            SettingsCard {
                kvRow("Full sync in flight", session.fullSync.inFlight ? "yes" : "no")
                kvRow("Attempted this session", session.fullSync.attempted ? "yes" : "no")
                kvRow("Progress", "\(session.fullSync.progress)%")
                kvRow("Chunks landed", "\(session.fullSync.chunks)")
                kvRow("Fresh / dupe messages",
                      "\(session.fullSync.fresh) fresh / \(session.fullSync.dupe) dupe")
                kvRow("History backfill completed",
                      UserDefaults.standard.bool(forKey: "historyBackfillCompleted") ? "yes" : "no")
                kvRow("Connection", connectionLabel(session.connection))
                kvRow("Syncing banner", session.syncing ? "yes" : "no")
            }
        }
    }

    private func connectionLabel(_ c: SessionViewModel.Connection) -> String {
        switch c {
        case .connecting: return "connecting"
        case .online:     return "online"
        case .offline:    return "offline"
        }
    }

    // MARK: - JID lookup

    private var jidLookupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("JID lookup")
            SettingsCard {
                SettingsRow(label: "Probe JID") {
                    TextField("user@s.whatsapp.net", text: $probeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 260)
                }
                kvRow("bare", probeBare)
                kvRow("canonical", probeCanonical)
                kvRow("displayName", probeDisplayName)
                kvRow("isSavedContact", probeIsSaved)
            }
        }
    }

    private var probeBare: String {
        probeInput.isEmpty ? "—" : JIDNormalize.bare(probeInput)
    }
    private var probeCanonical: String {
        probeInput.isEmpty ? "—"
            : JIDNormalize.canonical(probeInput, client: session.client)
    }
    private var probeDisplayName: String {
        probeInput.isEmpty ? "—" : session.displayName(for: probeInput)
    }
    private var probeIsSaved: String {
        probeInput.isEmpty ? "—" : (session.isSavedContact(probeInput) ? "yes" : "no")
    }

    // MARK: - SQLite indices

    private var indicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("SQLite indices")
            SettingsCard {
                if indexStatus.isEmpty {
                    SettingsRow(label: "Store") {
                        Text("unavailable")
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    ForEach(indexStatus, id: \.name) { row in
                        kvRow(row.name, row.present ? "present" : "missing")
                    }
                }
            }
        }
    }

    // MARK: - Stored history

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Stored history")
            SettingsCard {
                if let s = historyStats {
                    kvRow("Total messages", "\(s.totalMessages)")
                    kvRow("Distinct chats", "\(s.distinctChats)")
                    kvRow("Oldest", formatTimestamp(s.oldestMacEpoch))
                    kvRow("Newest", formatTimestamp(s.newestMacEpoch))
                    kvRow("Distinct senders", "\(s.distinctSenders)")
                    kvRow("Senders w/ push-name", "\(s.sendersWithPushName)")
                    kvRow("Push-name coverage", pushCoverageLabel(s))
                } else {
                    SettingsRow(label: "Store") {
                        Text("unavailable")
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Bridge call counts

    // F65: shows per-method WAClient invocation totals so we can spot
    // bridge methods firing too often (suspected source of phone-side
    // battery drain via repeated IQ traffic). Sorted descending so heavy
    // hitters surface first.
    private var bridgeCallCountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("Bridge call counts")
            SettingsCard {
                SettingsRow(label: "Total calls") {
                    Text("\(callCountsTotal)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }
            SettingsCard {
                if sortedCallCounts.isEmpty {
                    SettingsRow(label: "Calls") {
                        Text("none")
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    ForEach(sortedCallCounts, id: \.key) { entry in
                        SettingsRow(label: entry.key) {
                            Text("\(entry.value)")
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    private var sortedCallCounts: [(key: String, value: Int)] {
        callCountsCache.sorted { $0.value > $1.value }
    }

    private var callCountsTotal: Int {
        callCountsCache.values.reduce(0, +)
    }

    private func refreshCallCounts() {
        callCountsCache = session.client?.callCountsSnapshot() ?? [:]
    }

    private func pushCoverageLabel(_ s: HistoryStats) -> String {
        guard s.distinctSenders > 0 else { return "—" }
        let pct = Double(s.sendersWithPushName) / Double(s.distinctSenders) * 100
        return String(format: "%.1f%%", pct)
    }

    private func formatTimestamp(_ macEpoch: Double?) -> String {
        guard let macEpoch else { return "—" }
        // Core Data column ZTIMESTAMP is Mac reference date (2001-01-01 UTC).
        let date = Date(timeIntervalSince1970: macEpoch + 978_307_200)
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Row helper

    private func kvRow(_ label: String, _ value: String) -> some View {
        SettingsRow(label: label) {
            Text(value)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - SQLite probes

    /// Expected `yawac_idx_*` index names, mirrored from
    /// `SwiftDataIndexes.statements`. Kept in sync manually — the
    /// statements there are `private` and we only need the names for a
    /// presence check.
    private static let expectedIndexNames: [String] = [
        "yawac_idx_msg_chat",
        "yawac_idx_msg_ts",
        "yawac_idx_msg_chat_ts",
        "yawac_idx_react_chat",
        "yawac_idx_react_target",
        "yawac_idx_react_ts",
        "yawac_idx_poll_chat",
        "yawac_idx_poll_msg",
        "yawac_idx_poll_ts",
    ]

    private func computeIndexStatus() {
        guard let url = SwiftDataIndexes.defaultStoreURL else {
            indexStatus = []
            return
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            indexStatus = []
            return
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT count(*) FROM sqlite_master WHERE type='index' AND name=?"
        var rows: [(name: String, present: Bool)] = []
        for name in Self.expectedIndexNames {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                rows.append((name, false))
                continue
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            var present = false
            if sqlite3_step(stmt) == SQLITE_ROW {
                present = sqlite3_column_int(stmt, 0) > 0
            }
            sqlite3_finalize(stmt)
            rows.append((name, present))
        }
        indexStatus = rows
    }

    private func computeHistoryStats() {
        guard let url = SwiftDataIndexes.defaultStoreURL else {
            historyStats = nil
            return
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            historyStats = nil
            return
        }
        defer { sqlite3_close(db) }
        let total = scalarInt(db, "SELECT count(*) FROM ZPERSISTEDMESSAGE") ?? 0
        let chats = scalarInt(db, "SELECT count(DISTINCT ZCHATJID) FROM ZPERSISTEDMESSAGE") ?? 0
        let oldest = scalarDouble(db, "SELECT MIN(ZTIMESTAMP) FROM ZPERSISTEDMESSAGE")
        let newest = scalarDouble(db, "SELECT MAX(ZTIMESTAMP) FROM ZPERSISTEDMESSAGE")
        let senders = scalarInt(db, "SELECT count(DISTINCT ZSENDERJID) FROM ZPERSISTEDMESSAGE") ?? 0
        let withPush = scalarInt(db, """
            SELECT count(DISTINCT ZSENDERJID) FROM ZPERSISTEDMESSAGE
             WHERE ZSENDERPUSHNAME IS NOT NULL AND ZSENDERPUSHNAME != ''
            """) ?? 0
        historyStats = HistoryStats(
            totalMessages: total,
            distinctChats: chats,
            oldestMacEpoch: oldest,
            newestMacEpoch: newest,
            distinctSenders: senders,
            sendersWithPushName: withPush
        )
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func scalarDouble(_ db: OpaquePointer?, _ sql: String) -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    private struct HistoryStats {
        let totalMessages: Int
        let distinctChats: Int
        let oldestMacEpoch: Double?
        let newestMacEpoch: Double?
        let distinctSenders: Int
        let sendersWithPushName: Int
    }
}

// SQLite needs a stable transient destructor pointer when binding Swift
// strings; the canonical SQLITE_TRANSIENT macro is C-only.
private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)
