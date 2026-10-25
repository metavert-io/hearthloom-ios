import SwiftUI

/// Photo-location source (Track B / Phase 3). Requests Photos access and scans
/// geotags to the node. Only location + time + filename leave the device — never
/// images. Uploading is live (`PhotoIngestConfig.streamingEnabled`).
struct PhotosView: View {
    let connection: Connection
    @ObservedObject var ingest: PhotoLocationIngest

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Photo locations", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                    Text("Reads where your photos were taken and adds those places to your map. Only the location, time, and filename are sent — never the photos themselves.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }

            Section("Status") {
                LabeledContent("Access", value: statusText)
                LabeledContent("Streaming to", value: connection.baseURL.host ?? "—")
                LabeledContent("Last synced", value: DeviceSync.relative(ingest.lastSyncedAt))
                if ingest.scanning {
                    LabeledContent("Photos scanned", value: "\(ingest.scannedCount)")
                }
                LabeledContent("Geotagged found", value: "\(ingest.totalToSync)")
                LabeledContent("Locations synced",
                               value: ingest.totalToSync > 0
                               ? "\(ingest.syncedCount) / \(ingest.totalToSync)"
                               : "\(ingest.syncedCount)")
                if !PhotoIngestConfig.streamingEnabled {
                    Label("Uploading is pending the node’s /v1/ingest/photos endpoint.",
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
                    Task { await ingest.requestAuthorization(); await ingest.scan() }
                } label: {
                    HStack {
                        if ingest.scanning { ProgressView().padding(.trailing, 6) }
                        Label(ingest.scanning ? "Scanning…" : "Connect Photos",
                              systemImage: "photo.badge.plus")
                    }.frame(maxWidth: .infinity)
                }
                .disabled(ingest.authState == .denied || ingest.scanning)

                if ingest.authState == .authorized || ingest.authState == .limited {
                    Button {
                        Task { await ingest.forceResync() }
                    } label: {
                        Label("Re-sync all photos", systemImage: "arrow.clockwise")
                    }
                    .disabled(ingest.scanning)
                }
            } footer: {
                if ingest.authState == .denied {
                    Text("Photos access is denied. Enable it in Settings → Privacy → Photos.")
                } else if ingest.authState == .limited {
                    Text("Limited access — only the photos you selected are scanned.")
                }
            }
        }
        .navigationTitle("Photo locations")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
    }

    private var statusText: String {
        switch ingest.authState {
        case .unknown: return "Not connected"
        case .denied: return "Denied"
        case .limited: return "Limited"
        case .authorized: return "Connected"
        }
    }
}
