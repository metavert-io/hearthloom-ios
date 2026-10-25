import AppIntents
import Foundation

/// High-fidelity Focus capture: a **Focus Filter** App Intent. Once the user adds
/// "Hearthloom" as a filter to a Focus (Settings → Focus → [a Focus] → Focus
/// Filters), the system **background-launches the app and runs `perform()` on every
/// activation and deactivation** — mode-aware and precise, unlike the boolean
/// foreground sampling of `INFocusStatusCenter` alone.
///
/// `perform()` can't upload (the device token is biometric-gated and there's no
/// user present during a background launch), so it records the transition to
/// `FocusEventStore`; `FocusIngest` drains and streams it on next foreground.
struct HearthloomFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Record this Focus in Hearthloom"

    static var description: IntentDescription? =
        IntentDescription("Logs when this Focus turns on and off so it becomes part of your Hearthloom graph. Nothing leaves the device until the app next syncs.")

    /// The user names the Focus when adding the filter (e.g. "Work", "Sleep"),
    /// giving us the mode that the public status API can't provide.
    @Parameter(title: "Focus name", default: "Focus")
    var label: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Hearthloom: \(label)")
    }

    func perform() async throws -> some IntentResult {
        // `Self.current` returns the applied filter, or throws `.notFound` when no
        // Hearthloom filter is currently active — our activate/deactivate signal.
        let active = ((try? await Self.current) != nil)
        FocusEventStore.append(FocusEvent(on: active, mode: label, at: Date()))
        return .result()
    }
}
