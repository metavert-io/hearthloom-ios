import SwiftUI

/// Apple Health connection (Track B / Phase 1). Requests HealthKit read access
/// and starts the anchored-query pipeline, streaming to the node's
/// `POST /v1/ingest/health` (`HealthIngestConfig.streamingEnabled`).
struct HealthView: View {
    let connection: Connection
    @ObservedObject var ingest: HealthKitIngest

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Apple Health", systemImage: "heart.text.square")
                        .font(.headline)
                    Text("Streams your health samples to this node as they arrive. Daily summaries are minted server-side once each day closes; nothing health-related is stored on this phone beyond HealthKit itself.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }

            Section("Status") {
                LabeledContent("Access", value: statusText)
                LabeledContent("Streaming to", value: connection.baseURL.host ?? "—")
                LabeledContent("Last synced", value: DeviceSync.relative(ingest.lastSyncedAt))
                LabeledContent("Synced this session", value: "\(ingest.lastBatchCount)")
                if !HealthIngestConfig.streamingEnabled {
                    Label("Uploading is pending the node’s /v1/ingest/health endpoint.",
                          systemImage: "clock.badge")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let err = ingest.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        await ingest.requestAuthorization()
                        ingest.start()
                    }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(ingest.authState == .unavailable)

                if ingest.authState == .authorized {
                    Button {
                        ingest.forceResync()
                    } label: {
                        Label("Re-sync all history", systemImage: "arrow.clockwise")
                    }
                }
            } footer: {
                if ingest.authState == .unavailable {
                    Text("HealthKit isn’t available on this device.")
                }
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
    }

    private var statusText: String {
        switch ingest.authState {
        case .unknown: return "Not connected"
        case .unavailable: return "Unavailable"
        case .denied: return "Denied"
        case .authorized: return "Connected"
        }
    }
}
