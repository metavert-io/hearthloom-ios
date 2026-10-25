import AppIntents
import SwiftUI
import WidgetKit

/// Setup checklist for the ways to capture without opening the app. iOS has no
/// API to add a control for the user (or to open the control gallery), so this
/// walks them through it and — the part an app *can* do — detects when the
/// control has been added, re-checking each time the app comes back to the
/// foreground so the row ticks itself off.
struct CaptureSetupSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlAdded = false
    @State private var place: Place = .controlCenter

    enum Place: String, CaseIterable, Identifiable {
        case controlCenter = "Control Center", lockScreen = "Lock Screen", actionButton = "Action Button"
        var id: String { rawValue }
        var steps: [String] {
            switch self {
            case .controlCenter:
                return ["Swipe down from the top-right corner of the screen.",
                        "Touch and hold an empty area, then tap **Add a Control**.",
                        "Search for **Hearthloom** and tap **Capture**."]
            case .lockScreen:
                return ["Touch and hold the Lock Screen, tap **Customize**, then **Lock Screen**.",
                        "Tap **–** on one of the two buttons at the bottom, then tap **+**.",
                        "Search for **Hearthloom** and tap **Capture**."]
            case .actionButton:
                return ["Open the **Settings** app and tap **Action Button**.",
                        "Swipe across to **Controls** and tap **Choose a Control**.",
                        "Search for **Hearthloom** and tap **Capture**."]
            }
        }
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: controlAdded ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.title3)
                        .foregroundStyle(controlAdded ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One-press control")
                        Text(controlAdded ? "Added — press it to capture"
                                          : "Not added yet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("capture.setup.control")
                Picker("Where", selection: $place) {
                    ForEach(Place.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(Array(place.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.footnote.bold().monospacedDigit())
                            .foregroundStyle(HearthTheme.accent)
                        Text(.init(step)).font(.footnote)
                    }
                }
            } header: {
                Text("Set up one-press capture")
            } footer: {
                Text("The control opens Hearthloom on a capture field. If the iPhone is locked, iOS asks for Face ID first. Come back here after adding it and this ticks itself off.")
            }
            .task(id: scenePhase) { await refresh() }
        }

        Section {
            SiriTipView(intent: CaptureToHearthloomIntent())
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            ShortcutsLink()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } header: {
            Text("Hands-free")
        } footer: {
            Text("Siri and Shortcuts capture in the background without opening the app, so they work while the iPhone stays locked. In Shortcuts, put **Dictate Text** before **Capture to Hearthloom** to speak it.")
        }
    }

    @available(iOS 18.0, *)
    private func refresh() async {
        let controls = (try? await ControlCenter.shared.currentControls()) ?? []
        controlAdded = controls.contains { $0.kind == CaptureLaunch.controlKind }
    }
}
