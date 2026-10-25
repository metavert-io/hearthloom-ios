import SwiftUI

@main
struct HearthloomApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() { Observability.start() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .task { app.bootstrap() }
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-lock when the app leaves the foreground so returning
                    // requires Face ID again. Only relock from `.connected`.
                    if newPhase == .background, app.phase == .connected {
                        app.phase = .locked
                    }
                }
        }
    }
}
