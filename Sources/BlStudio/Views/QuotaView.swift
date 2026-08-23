import SwiftUI
import Charts

struct KeyRow: Identifiable {
    var id: String
    var keyId: UUID?
    var label: String
    var masked: String?
}

struct QuotaView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: Per-key local usage
                Card(title: "Local usage per API key") {
                    Text("Tracked by BlStudio for every request it sends, grouped by the key selected at call time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(keyRows, id: \.id) { row in
                        KeyUsageCard(row: row)
                    }
                    if keyRows.isEmpty {
                        Text("No usage recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Account quota (console)
                Card(title: "Account quota (Bailian console)") {
                    HStack(spacing: 10) {
                        Text("Free-tier quotas and rate limits come from your console session, which belongs to the active bl profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await app.quota.refresh() }
                        } label: {
                            if app.quota.loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(app.quota.loading)
                    }

                    if let error = app.quota.quotaError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Could not load account quota").font(.callout.bold())
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))
                    }

                    if !app.quota.freeQuotas.isEmpty {
                        freeQuotaTable
                    }

                    if !app.quota.rateUsages.isEmpty {
                        rateUsageTable
                    }

                    if let refreshed = app.quota.lastRefreshed {
                        Text("Last refreshed \(Fmt.shortDate.string(from: refreshed))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // MARK: MiniMax quota (mmx CLI)
                Card(title: "MiniMax quota (token plan)") {
                    HStack(spacing: 10) {
                        Text("Remaining token-plan quota per model, via the mmx CLI (`mmx quota show`). Pay-as-you-go keys don't report model quotas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await app.quota.refreshMmx() }
                        } label: {
                            if app.quota.mmxLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(app.quota.mmxLoading)
                    }

                    if !app.quota.mmxQuota.isEmpty {
                        Table(app.quota.mmxQuota) {
                            TableColumn("Model") { r in
                                Text(r.model_name ?? "?")
                            }
                            TableColumn("Remaining") { r in
                                Text(mmxRemainingText(r))
                                    .monospacedDigit()
                            }
                            TableColumn("Used") { r in
                                if let pct = mmxUsagePercent(r) {
                                    HStack(spacing: 6) {
                                        ProgressView(value: min(pct, 100), total: 100)
                                            .frame(width: 70)
                                        Text("\(pct, specifier: "%.1f")%")
                                            .monospacedDigit()
                                    }
                                } else {
                                    Text("-").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(minHeight: 120)
                    } else if let err = app.quota.mmxQuotaError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !app.mmx.isAvailable() {
                        Text("Install the mmx CLI (`npm i -g mmx-cli`) to see MiniMax quotas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let refreshed = app.quota.mmxLastRefreshed {
                        Text("Last refreshed \(Fmt.shortDate.string(from: refreshed))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding()
        }
        .task {
            if app.quota.lastRefreshed == nil {
                await app.quota.refresh()
            }
        }
    }

    // MARK: rows

    var keyRows: [KeyRow] {
        var rows: [KeyRow] = []
        let usedIds = app.ledger.knownKeyIds
        // Stored keys first.
        for key in app.keysStore.keys where usedIds.contains(key.id) {
            rows.append(KeyRow(id: key.id.uuidString, keyId: key.id,
                               label: key.label, masked: key.masked))
        }
        // Default profile bucket if it has usage.
        if usedIds.contains(nil) {
            rows.append(KeyRow(id: "default", keyId: nil,
                               label: "CLI default profile", masked: app.authStatus?.api_key?.masked))
        }
        return rows
    }

    private func mmxRemainingText(_ r: MmxQuotaRemain) -> String {
        // status 3 means unlimited.
        if r.current_interval_status == 3 { return "unlimited" }
        guard let total = r.current_interval_total_count, total > 0 else { return "no plan quota" }
        let used = r.current_interval_usage_count ?? 0
        return "\(max(0, total - used)) of \(total) left"
    }

    private func mmxUsagePercent(_ r: MmxQuotaRemain) -> Double? {
        if let pct = r.current_interval_remaining_percent {
            return max(0, min(100, 100 - pct))
        }
        guard let total = r.current_interval_total_count, total > 0 else { return nil }
        let used = r.current_interval_usage_count ?? 0
        return Double(used) / Double(total) * 100
    }

    private var freeQuotaTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Free-tier quota").font(.subheadline.bold())
            Table(app.quota.freeQuotas) {
                TableColumn("Model", value: \.model)
                TableColumn("Remaining") { q in
                    Text(formatQuota(q))
                        .monospacedDigit()
                }
                TableColumn("Used") { q in
                    if let pct = q.usagePercent {
                        HStack(spacing: 6) {
                            ProgressView(value: min(pct, 100), total: 100)
                                .frame(width: 70)
                            Text("\(pct, specifier: "%.1f")%")
                                .monospacedDigit()
                        }
                    } else {
                        Text("-").foregroundStyle(.tertiary)
                    }
                }
                TableColumn("Expires") { q in
                    Text(q.expires ?? "-").font(.caption)
                }
                TableColumn("Auto-stop") { q in
                    switch q.autoStop {
                    case .some(true): Text("on").foregroundStyle(.green)
                    case .some(false): Text("off").foregroundStyle(.secondary)
                    case nil: Text("-").foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minHeight: 220)
        }
    }

    private var rateUsageTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rate limits (recent usage vs RPM/TPM)").font(.subheadline.bold())
            Table(app.quota.rateUsages) {
                TableColumn("Model", value: \.model)
                TableColumn("RPM") { r in
                    Text("\(r.rpmUsage ?? 0) / \(r.rpmLimit ?? 0)")
                        .monospacedDigit()
                }
                TableColumn("TPM") { r in
                    Text("\(Fmt.tokens(r.tpmUsage ?? 0)) / \(Fmt.tokens(r.tpmLimit ?? 0))")
                        .monospacedDigit()
                }
                TableColumn("Headroom") { r in
                    if let left = r.rpmQuotaLeft {
                        Text("\(left, specifier: "%.0f")% free")
                            .foregroundStyle(left < 20 ? .red : .secondary)
                    } else {
                        Text("-").foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }

    private func formatQuota(_ q: FreeTierQuota) -> String {
        if let r = q.remaining, let t = q.total {
            return "\(Fmt.tokens(Int(r))) / \(Fmt.tokens(Int(t)))"
        }
        return "-"
    }
}

// MARK: - Per-key usage card

struct KeyUsageCard: View {
    @Environment(AppState.self) private var app
    let row: KeyRow

    var body: some View {
        let summary = app.ledger.summary(keyId: row.keyId)
        let series = app.ledger.dailySeries(keyId: row.keyId)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal").foregroundStyle(.secondary)
                        Text(row.label).font(.callout.bold())
                    }
                    if let masked = row.masked {
                        Text(masked).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let last = summary.lastUsed {
                    Text("last used \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 20) {
                stat("Images", "\(summary.images)")
                stat("Edits", "\(summary.edits)")
                if summary.videos > 0 {
                    stat("Videos", "\(summary.videos)")
                }
                if summary.music > 0 {
                    stat("Music", "\(summary.music)")
                }
                if summary.audio > 0 {
                    stat("Speech", "\(summary.audio)")
                }
                stat("Chats", "\(summary.chats)")
                stat("Tokens", Fmt.tokens(summary.totalTokens))
                stat("Today", "\(summary.todayImages) img")
                if summary.failed > 0 {
                    stat("Failed", "\(summary.failed)")
                }
            }

            Chart(series, id: \.day) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Images", point.images)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 90)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
