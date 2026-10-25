import SwiftUI

/// Connection details + disconnect. The device PAT stays revocable server-side
/// (dashboard → API Keys); disconnect only forgets it locally.
struct SettingsView: View {
    let connection: Connection
    @ObservedObject var adapters: DeviceAdapters
    @EnvironmentObject var app: AppState
    @State private var confirmDisconnect = false
    @State private var detail: DataSourceDetail?
    @StateObject private var capture = CaptureModel()

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Name", value: connection.displayName)
                LabeledContent("Server", value: connection.baseURL.host ?? connection.baseURL.absoluteString)
                LabeledContent("Method", value: originLabel)
                LabeledContent("Token scopes", value: "read, ingest, notify")
            }

            Section {
                HealthChecklistRow(ingest: adapters.health) { detail = .health }
                PhotosChecklistRow(ingest: adapters.photos) { detail = .photos }
                AdapterChecklistRow(title: "Contacts", systemImage: "person.2",
                                    adapter: adapters.contacts) { detail = .contacts }
                AdapterChecklistRow(title: "Calendar", systemImage: "calendar",
                                    adapter: adapters.calendar) { detail = .calendar }
                AdapterChecklistRow(title: "Reminders", systemImage: "checklist",
                                    adapter: adapters.reminders) { detail = .reminders }
                AdapterChecklistRow(title: "Motion & trips", systemImage: "figure.walk.motion",
                                    adapter: adapters.motion) { detail = .motion }
                AdapterChecklistRow(title: "Music & podcasts", systemImage: "music.note",
                                    adapter: adapters.media) { detail = .media }
                AdapterChecklistRow(title: "Location & visits", systemImage: "mappin.and.ellipse",
                                    adapter: adapters.location) { detail = .location }
                AdapterChecklistRow(title: "Focus", systemImage: "moon.circle",
                                    adapter: adapters.focus) { detail = .focus }
            } header: {
                Text("iOS Data Sources")
            } footer: {
                Text("Tap **Connect** to enable a source. Tap a row to see its details and sync history.")
            }

            Section {
                NavigationLink {
                    CaptureView(connection: connection, model: capture)
                } label: {
                    LabeledContent {
                        Text(capture.rowStatus)
                    } label: {
                        Label("Quick capture", systemImage: "square.and.pencil")
                    }
                }
                NavigationLink {
                    ScanView(host: host, ingest: adapters.scan)
                } label: {
                    Label("Scan documents", systemImage: "doc.viewfinder")
                }
                NavigationLink {
                    SyncHistoryView(connection: connection)
                } label: {
                    Label("Sync history", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("Security") {
                Label("Device token stored behind \(BiometricGate.biometryName)",
                      systemImage: "faceid")
                    .font(.footnote)
                Text("Revoke this device anytime from the dashboard’s **API Keys** list.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) { confirmDisconnect = true } label: {
                    Label("Disconnect this device", systemImage: "xmark.circle")
                }
            } footer: {
                Text("Forgets the connection on this phone. The token remains valid on the server until you revoke it there.")
            }

            Section {
                LabeledContent("App version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
        .navigationDestination(item: $detail) { dataSourceDetail(for: $0) }
        .confirmationDialog("Disconnect this device?", isPresented: $confirmDisconnect,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { app.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to sign in again to reconnect.")
        }
    }

    private var host: String { connection.baseURL.host ?? "—" }

    @ViewBuilder
    private func dataSourceDetail(for detail: DataSourceDetail) -> some View {
        switch detail {
        case .health:
            HealthView(connection: connection, ingest: adapters.health)
        case .photos:
            PhotosView(connection: connection, ingest: adapters.photos)
        case .contacts:
            AdapterView(title: "Contacts", subtitle: "Your address book seeds people in your graph so other data links to the right person. Metadata only.",
                        systemImage: "person.2", host: host, adapter: adapters.contacts)
        case .calendar:
            AdapterView(title: "Calendar", subtitle: "Your events, attendees, and places link people, times, and locations together.",
                        systemImage: "calendar", host: host, adapter: adapters.calendar)
        case .reminders:
            AdapterView(title: "Reminders", subtitle: "Your reminders and their due dates flow into your tasks.",
                        systemImage: "checklist", host: host, adapter: adapters.reminders)
        case .motion:
            AdapterView(title: "Motion", subtitle: "Walking, running, cycling, and driving segments — how you move through the day.",
                        systemImage: "figure.walk.motion", host: host, adapter: adapters.motion)
        case .media:
            AdapterView(title: "Music", subtitle: "What you listen to — songs and podcasts you've played — as a taste signal.",
                        systemImage: "music.note", host: host, adapter: adapters.media)
        case .location:
            AdapterView(title: "Location & visits", subtitle: "The places you spend time — arrivals and departures — build your personal place graph. Grant “Always” so visits record in the background. Coordinates and times only.",
                        systemImage: "mappin.and.ellipse", host: host, adapter: adapters.location)
        case .focus:
            AdapterView(title: "Focus", subtitle: "When a Focus (Work, Sleep, Do Not Disturb, …) is on. For background, mode-aware recording, add Hearthloom as a Focus Filter in iOS Settings → Focus → (your Focus) → Focus Filters.",
                        systemImage: "moon.circle", host: host, adapter: adapters.focus)
        }
    }

    private var originLabel: String {
        switch connection.origin {
        case .selfHostSignIn: return "Self-host (sign-in)"
        case .selfHostPastedPAT: return "Self-host (device token)"
        case .hostedNew: return "Hosted provider (new account)"
        case .hostedSignIn: return "Hosted provider (sign-in)"
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
