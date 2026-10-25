import AppIntents
import SwiftUI
import WidgetKit

/// The Lock Screen / Control Center / Action Button control. One press opens
/// Hearthloom on the capture field (see `OpenCaptureIntent`). It shows a fixed
/// label only — never anything from the record.
struct CaptureControl: ControlWidget {
    static let kind = CaptureLaunch.controlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Capture to Hearthloom")
        .description("Open Hearthloom ready to capture a thought.")
    }
}

@main
struct HearthloomControlsBundle: WidgetBundle {
    var body: some Widget {
        CaptureControl()
    }
}
