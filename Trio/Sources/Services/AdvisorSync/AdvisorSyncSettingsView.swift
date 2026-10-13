import SwiftUI

/// Settings row for the Diabetics Advisor export: a manual "Sync to iCloud now" button plus
/// the outcome of the last sync, so the user can confirm the pipeline works without waiting
/// for a loop cycle. Advisory only — read-only, never changes Trio.
struct AdvisorSyncSettingsView: View {
    let manager: AdvisorSyncManager

    @State private var isSyncing = false
    @State private var status: AdvisorSyncStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Export your settings and recent data to the private Diabetics Advisor app via your iCloud account. Read-only — it never changes Trio."
            )
            .font(.footnote)
            .foregroundColor(.secondary)

            Button {
                guard !isSyncing else { return }
                isSyncing = true
                Task {
                    let result = await manager.syncAndReport()
                    await MainActor.run {
                        status = result
                        isSyncing = false
                    }
                }
            } label: {
                HStack {
                    Text("Sync to iCloud now").foregroundColor(.primary)
                    Spacer()
                    if isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(isSyncing)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let s = status {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: s.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(s.success ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.message).font(.footnote)
                        Text(s.date, style: .relative).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear { if status == nil { status = manager.lastStatus } }
    }
}
