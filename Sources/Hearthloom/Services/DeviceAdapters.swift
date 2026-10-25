import Foundation

/// App-level owner of the Track B device adapters so they keep streaming while
/// the app is open — regardless of which screen is showing. Previously each
/// adapter was a view-scoped `@StateObject`, so ingest only ran while its
/// Settings screen was on-screen (the "Last synced: Never" bug). Held by
/// `ShellView` for the whole authenticated session and kicked on foreground.
@MainActor
final class DeviceAdapters: ObservableObject {
    let health: HealthKitIngest
    let photos: PhotoLocationIngest
    let contacts: ContactsIngest
    let calendar: CalendarIngest
    let reminders: RemindersIngest
    let motion: MotionIngest
    let media: MediaIngest
    let location: LocationVisitsIngest
    let scan: VisionScanIngest   // user-driven capture; no auto-resume
    let focus: FocusIngest
    private let connection: Connection

    init(connection: Connection) {
        self.connection = connection
        health = HealthKitIngest(connection: connection)
        photos = PhotoLocationIngest(connection: connection)
        contacts = ContactsIngest(connection: connection)
        calendar = CalendarIngest(connection: connection)
        reminders = RemindersIngest(connection: connection)
        motion = MotionIngest(connection: connection)
        media = MediaIngest(connection: connection)
        location = LocationVisitsIngest(connection: connection)
        scan = VisionScanIngest(connection: connection)
        focus = FocusIngest(connection: connection)
    }

    /// Resume streaming for adapters the user already connected. HealthKit's
    /// `requestAuthorization` is a no-op prompt-wise when already granted, so
    /// this never nags; the photo scan is incremental (only new photos).
    func startEnabled() {
        if HealthKitIngest.isEnabled {
            Task { await health.requestAuthorization(); health.start() }
        }
        if PhotoLocationIngest.isEnabled {
            Task { await photos.scan() }
        }
        if ContactsIngest.isEnabled { Task { await contacts.scan() } }
        if CalendarIngest.isEnabled { Task { await calendar.scan() } }
        if RemindersIngest.isEnabled { Task { await reminders.scan() } }
        if MotionIngest.isEnabled { Task { await motion.scan() } }
        if MediaIngest.isEnabled { Task { await media.scan() } }
        // Visits are delegate-driven: resume monitoring, then flush anything
        // captured (incl. background relaunches) that hasn't been sent yet.
        if LocationVisitsIngest.isEnabled { location.start(); Task { await location.scan() } }
        // Focus can only be sampled while the app is foreground — do it now.
        if FocusIngest.isEnabled { Task { await focus.scan() } }
        // Capture is always on: make sure the write-only capture key exists,
        // then upload anything queued while offline or locked.
        let connection = self.connection
        Task {
            await CaptureService.shared.ensureKey(connection: connection)
            await CaptureService.shared.drain(connection: connection)
        }
    }
}
