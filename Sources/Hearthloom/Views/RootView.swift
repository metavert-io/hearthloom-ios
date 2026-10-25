import SwiftUI

/// Top-level router keyed off `AppState.phase`.
struct RootView: View {
    @EnvironmentObject var app: AppState

    @State private var showCapture = false

    var body: some View {
        phaseView
            // The capture control opens the app here, whatever phase it is in.
            .sheet(isPresented: $showCapture) { QuickCaptureSheet(connection: app.connection) }
            .onReceive(NotificationCenter.default.publisher(for: CaptureLaunch.requested)) { _ in
                if CaptureLaunch.consume() { showCapture = true }
            }
            .task { if CaptureLaunch.consume() { showCapture = true } }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch app.phase {
        case .launching:
            LaunchView()
        case .locked:
            LockView()
        case .needsConnection:
            ConnectView()
        case .connected:
            if let connection = app.connection {
                ShellView(connection: connection)
            } else {
                // Shouldn't happen; fall back to connect.
                ConnectView()
            }
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            HearthTheme.background.ignoresSafeArea()
            ProgressView().tint(HearthTheme.accent)
        }
    }
}
