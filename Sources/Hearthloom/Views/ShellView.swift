import SwiftUI

/// The authenticated shell: a native tab bar around the dashboard webview, plus
/// Vault and Settings tabs. Owns the `DashboardModel` for the connection.
struct ShellView: View {
    let connection: Connection
    @EnvironmentObject var app: AppState
    @StateObject private var dashboard: DashboardModel
    @StateObject private var vault: VaultStatus
    @StateObject private var adapters: DeviceAdapters
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedLoad = false
    @State private var showReconnect = false

    init(connection: Connection) {
        self.connection = connection
        _dashboard = StateObject(wrappedValue: DashboardModel(connection: connection))
        _vault = StateObject(wrappedValue: VaultStatus(connection: connection))
        _adapters = StateObject(wrappedValue: DeviceAdapters(connection: connection))
    }

    var body: some View {
        TabView {
            dashboardTab
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { NotificationsView(connection: connection) }
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
            NavigationStack { VaultView(connection: connection, vault: vault) }
                .tabItem {
                    Label(vault.locked ? "Vault" : "Unlocked",
                          systemImage: vault.locked ? "lock.fill" : "lock.open.fill")
                }
            NavigationStack { SettingsView(connection: connection, adapters: adapters) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(HearthTheme.accent)
        .onAppear {
            guard !startedLoad else { return }
            startedLoad = true
            dashboard.start(cookies: app.takeSessionCookies())
            Task { await vault.refresh() }
            adapters.startEnabled()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vault.refresh() }; adapters.startEnabled() }
        }
        .onChange(of: dashboard.externalURL) { _, url in
            if let url { openURL(url); dashboard.externalURL = nil }
        }
    }

    // No native top bar here — the hearthloom web SPA provides its own top nav.
    // We keep only a thin loading indicator and the reconnect/error banners.
    private var dashboardTab: some View {
        ZStack(alignment: .top) {
            WebDashboardView(model: dashboard)
                .ignoresSafeArea(.container, edges: .bottom)
            if dashboard.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(HearthTheme.accent)
            }
            if dashboard.needsWebAuth {
                ReconnectBanner { showReconnect = true }
            } else if let err = dashboard.lastError {
                ErrorBanner(message: err) { dashboard.reload() }
            }
        }
        .sheet(isPresented: $showReconnect) {
            ReconnectSheet(model: dashboard)
        }
    }
}

private struct ReconnectBanner: View {
    let action: () -> Void
    var body: some View {
        VStack {
            Spacer()
            Button(action: action) {
                HStack {
                    Image(systemName: "person.badge.key")
                    Text("Dashboard sign-in needed").font(.footnote.bold())
                    Spacer()
                    Text("Reconnect").font(.footnote.bold())
                }
                .padding()
                .background(HearthTheme.accent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HearthTheme.accent, lineWidth: 1))
                .padding()
            }
            .tint(HearthTheme.accent)
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Image(systemName: "wifi.exclamationmark")
                Text(message).font(.footnote).lineLimit(2)
                Spacer()
                Button("Retry", action: retry).font(.footnote.bold())
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}
