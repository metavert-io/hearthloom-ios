import SwiftUI

/// Which data-source detail screen the checklist is navigating to.
enum DataSourceDetail: String, Identifiable, Hashable {
    case health, photos, contacts, calendar, reminders, motion, media, location, focus
    var id: String { rawValue }
}

/// Checklist-style rows for the "iOS Data Sources" section of Settings. Each row
/// shows the source, its connected/not state, and an inline **Connect** button so
/// the user can enable sources straight down the list without opening each detail
/// screen first. Tapping the row (icon/title area) still opens the full detail
/// view. Health and Photos have bespoke state, so they get dedicated rows; the
/// five uniform `DeviceAdapter` conformers share `AdapterChecklistRow`.

/// Presentational body shared by every row — no adapter knowledge, just values.
struct ChecklistRowBody: View {
    let title: String
    let systemImage: String
    let statusText: String
    let connected: Bool
    let busy: Bool
    var needsAttention: Bool = false
    let onConnect: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDetail) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(connected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                            .frame(width: 32, height: 32)
                        Image(systemName: systemImage)
                            .font(.system(size: 15))
                            .foregroundStyle(connected ? Color.green : Color.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if busy {
                ProgressView()
            } else if connected && needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            } else if connected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else {
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
                    .tint(HearthTheme.accent)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Row for the five uniform adapters (contacts, calendar, reminders, motion, media).
struct AdapterChecklistRow<A: DeviceAdapter>: View {
    let title: String
    let systemImage: String
    @ObservedObject var adapter: A
    let onOpenDetail: () -> Void

    var body: some View {
        ChecklistRowBody(
            title: title, systemImage: systemImage,
            statusText: adapter.statusText, connected: adapter.connected, busy: adapter.busy,
            needsAttention: adapter.settingsHint != nil,
            onConnect: { Task { await adapter.connect() } },
            onOpenDetail: onOpenDetail)
    }
}

/// HealthKit hides read-authorization, so "connected" tracks its `authState`.
struct HealthChecklistRow: View {
    @ObservedObject var ingest: HealthKitIngest
    let onOpenDetail: () -> Void
    @State private var connecting = false

    private var connected: Bool { ingest.authState == .authorized }
    private var statusText: String {
        switch ingest.authState {
        case .authorized: return "Connected"
        case .denied: return "Denied"
        case .unavailable: return "Unavailable"
        case .unknown: return "Not connected"
        }
    }

    var body: some View {
        ChecklistRowBody(
            title: "Apple Health", systemImage: "heart.text.square",
            statusText: statusText, connected: connected, busy: connecting,
            onConnect: {
                Task {
                    connecting = true
                    await ingest.requestAuthorization()
                    ingest.start()
                    connecting = false
                }
            },
            onOpenDetail: onOpenDetail)
    }
}

/// Photos supports full or limited access; both count as connected.
struct PhotosChecklistRow: View {
    @ObservedObject var ingest: PhotoLocationIngest
    let onOpenDetail: () -> Void

    private var connected: Bool { ingest.authState == .authorized || ingest.authState == .limited }
    private var statusText: String {
        switch ingest.authState {
        case .authorized: return "Connected"
        case .limited: return "Limited access"
        case .denied: return "Denied"
        case .unknown: return "Not connected"
        }
    }

    var body: some View {
        ChecklistRowBody(
            title: "Photo locations", systemImage: "photo.on.rectangle.angled",
            statusText: statusText, connected: connected, busy: ingest.scanning,
            onConnect: { Task { await ingest.requestAuthorization(); await ingest.scan() } },
            onOpenDetail: onOpenDetail)
    }
}
