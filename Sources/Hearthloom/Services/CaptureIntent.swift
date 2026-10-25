import AppIntents
import Foundation

/// "Capture to Hearthloom": one intent behind Siri, Shortcuts and the Action
/// Button (through a shortcut). It runs in the background — the app is not
/// opened — so it works from a locked phone: the text parameter is filled by
/// Siri dictation or a Shortcuts input, the thought is queued on disk, and an
/// upload is attempted with the write-only capture key.
///
/// It succeeds as soon as the item is queued. The reply only ever confirms the
/// save; it never repeats the text or anything from the record, since it can be
/// spoken or shown on the Lock Screen.
struct CaptureToHearthloomIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to Hearthloom"

    static var description: IntentDescription? =
        IntentDescription("Files a thought in Hearthloom as a task or a note. Works offline: it is saved on this iPhone and uploaded when your node is reachable.")

    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to capture?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text) to Hearthloom")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try await CaptureService.shared.capture(text: text)
        } catch CaptureInputError.empty {
            throw $text.needsValueError("What do you want to capture?")
        }
        await CaptureService.shared.drain(budget: CaptureIngestConfig.intentUploadBudget)
        return .result(dialog: Self.confirmation(queued: CaptureQueue.shared.count,
                                                 keyRejected: CaptureStatus().keyRejected))
    }

    static func confirmation(queued: Int, keyRejected: Bool) -> IntentDialog {
        if queued == 0 { return "Saved to Hearthloom." }
        if keyRejected { return "Saved on this iPhone. Open Hearthloom to reconnect capture." }
        return "Saved. It will upload to Hearthloom when your node is reachable."
    }
}

/// Registers the intent with Siri and Spotlight with no setup, and makes it the
/// suggested action when the user builds an Action Button shortcut.
struct HearthloomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToHearthloomIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Capture a thought in \(.applicationName)",
                "Add a note to \(.applicationName)",
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil")
    }
}
