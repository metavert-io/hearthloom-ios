import SwiftUI
import UIKit

/// Minimal contract a device adapter exposes to the shared status screen.
@MainActor
protocol DeviceAdapter: ObservableObject {
    var statusText: String { get }
    var syncedCount: Int { get }
    var lastSyncedAt: Date? { get }
    var lastError: String? { get }
    var busy: Bool { get }
    var connected: Bool { get }
    var pendingNote: String? { get }
    /// Non-nil when the adapter needs the user to change something in iOS Settings
    /// (e.g. upgrade Location to "Always"). Drives a callout + "Open Settings"
    /// button in the detail screen and an attention marker on the checklist row.
    var settingsHint: String? { get }
    func connect() async
    func forceResync() async
}

extension DeviceAdapter {
    var settingsHint: String? { nil }
}

/// Reusable Settings screen for the simpler adapters (contacts, calendar, …).
struct AdapterView<A: DeviceAdapter>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let host: String
    @ObservedObject var adapter: A
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: systemImage).font(.headline)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if let hint = adapter.settingsHint {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(hint, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label("Open Settings", systemImage: "gear").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }.padding(.vertical, 4)
                }
            }
            Section("Status") {
                LabeledContent("Access", value: adapter.statusText)
                LabeledContent("Streaming to", value: host)
                LabeledContent("Last synced", value: DeviceSync.relative(adapter.lastSyncedAt))
                LabeledContent("Synced", value: "\(adapter.syncedCount)")
                if let note = adapter.pendingNote {
                    Label(note, systemImage: "clock.badge").font(.footnote).foregroundStyle(.secondary)
                }
                if let err = adapter.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Button { Task { await adapter.connect() } } label: {
                    HStack {
                        if adapter.busy { ProgressView().padding(.trailing, 6) }
                        Label(adapter.busy ? "Syncing…" : "Connect \(title)", systemImage: "link")
                    }.frame(maxWidth: .infinity)
                }
                .disabled(adapter.busy)
                if adapter.connected {
                    Button { Task { await adapter.forceResync() } } label: {
                        Label("Re-sync all", systemImage: "arrow.clockwise")
                    }
                    .disabled(adapter.busy)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
    }
}
