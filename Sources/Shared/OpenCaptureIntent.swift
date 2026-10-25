import AppIntents
import Foundation

/// Hand-off between `OpenCaptureIntent` and the app's UI: the intent flags that
/// a capture was asked for, and `RootView` presents the capture field.
enum CaptureLaunch {
    /// The control's `kind` — shared so the app can tell whether it's been added.
    static let controlKind = "com.metavert.hearthloom.capture"
    static let requested = Notification.Name("capture.openRequested")
    private static let lock = NSLock()
    private static var pending = false

    static func request() {
        lock.withLock { pending = true }
        NotificationCenter.default.post(name: requested, object: nil)
    }

    /// True once per request — covers a cold launch, where the intent runs
    /// before any view is listening for the notification.
    static func consume() -> Bool {
        lock.withLock { defer { pending = false }; return pending }
    }
}

/// Opens Hearthloom straight onto the capture field. This is what the Lock
/// Screen / Control Center control runs: a control can't collect text itself,
/// so it brings the app forward (iOS asks for Face ID first if the phone is
/// locked) with the keyboard up.
///
/// This file is compiled into BOTH the app and the controls extension — the
/// system only opens the app from a control when the intent is in both — and
/// `perform()` then runs in the app's process.
struct OpenCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Hearthloom Capture"
    static var description: IntentDescription? =
        IntentDescription("Opens Hearthloom ready to type or dictate a thought.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureLaunch.request()
        return .result()
    }
}
