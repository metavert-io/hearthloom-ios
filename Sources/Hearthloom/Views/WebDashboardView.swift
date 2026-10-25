import SwiftUI
import WebKit

/// Owns the `WKWebView` for a connection's dashboard and drives navigation.
/// Injects the fresh `hl_session` cookie (when we have one) so the dashboard SPA
/// renders authenticated on first load. Uses a persistent data store so the
/// session survives relaunches.
@MainActor
final class DashboardModel: NSObject, ObservableObject {
    let webView: WKWebView
    let connection: Connection

    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var lastError: String?

    /// True when the loaded dashboard is unauthenticated (session expired, or a
    /// paste-only-PAT connection that never had one) — the shell surfaces a
    /// native re-auth affordance instead of leaving the user at the login wall.
    @Published var needsWebAuth = false

    /// Set when an external/`_blank` link should open in Safari.
    @Published var externalURL: URL?

    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }

    init(connection: Connection) {
        self.connection = connection
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()               // persistent cookies
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true  // back-swipe
        webView.allowsLinkPreview = true
    }

    /// Inject cookies, then load `<baseURL>/`. With fresh onboarding cookies we
    /// use them directly; otherwise (relaunch, or a token-only connection) we
    /// derive a session from the durable device PAT
    /// (`POST /v1/auth/session-from-key`).
    func start(cookies: [HTTPCookie]) {
        Task {
            var toInject = cookies
            if toInject.isEmpty {
                toInject = (try? await api.sessionFromKey(pat: connection.deviceToken)) ?? []
            }
            await inject(toInject)
            load()
        }
    }

    /// Re-establish a session from credentials, inject it, and reload the
    /// dashboard. Called from the native re-auth sheet.
    func reauthenticate(email: String, password: String) async throws {
        let cookies = try await api.establishSession(email: email, password: password)
        await inject(cookies)
        needsWebAuth = false
        goHome()
    }

    /// Write cookies into the webview's persistent store.
    private func inject(_ cookies: [HTTPCookie]) async {
        guard !cookies.isEmpty else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for cookie in cookies { group.enter(); store.setCookie(cookie) { group.leave() } }
            group.notify(queue: .main) { cont.resume() }
        }
    }

    /// Snapshot the webview's current cookies (async completion → await).
    private func currentCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                cont.resume(returning: $0)
            }
        }
    }

    /// After a home-page load, ask the node whether the session is authenticated.
    fileprivate func probeAuth() async {
        // Only meaningful on our own node's pages.
        guard let host = connection.baseURL.host,
              webView.url?.host == host else { return }
        let cookies = await currentCookies()
        do {
            let state = try await api.webAuthState(cookies: cookies)
            needsWebAuth = state.required && !state.authenticated
        } catch {
            // Transient probe failure — don't nag; leave prior state.
        }
    }

    private func load() {
        var req = URLRequest(url: connection.baseURL)
        // Best-effort Bearer on the top document for token-only connections.
        // Subresource fetches won't carry it; they rely on the session `start`
        // minted from the device token.
        if connection.origin == .selfHostPastedPAT {
            req.setValue("Bearer \(connection.deviceToken)", forHTTPHeaderField: "Authorization")
        }
        webView.load(req)
    }

    func reload() { webView.reload() }
    func goHome() { webView.load(URLRequest(url: connection.baseURL)) }
    func goBack() { if webView.canGoBack { webView.goBack() } }
}

extension DashboardModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true; lastError = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false; canGoBack = webView.canGoBack
        Task { await probeAuth() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false; report(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false; report(error)
    }

    /// Route external links to Safari; keep same-origin in-app; support downloads.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async
                 -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.allow, preferences) }

        // Non-http schemes (mailto:, tel:, etc.) → system.
        if let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" {
            externalURL = url
            return (.cancel, preferences)
        }
        // Different host than our node → open externally (don't leak the session).
        if let nodeHost = connection.baseURL.host, let host = url.host, host != nodeHost {
            externalURL = url
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition"),
           disp.lowercased().contains("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) { download.delegate = self }

    private func report(_ error: Error) {
        let ns = error as NSError
        // Ignore benign "frame load interrupted" from cancelled external nav.
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        if ns.code == NSURLErrorCancelled { return }
        lastError = error.localizedDescription
    }
}

extension DashboardModel: WKUIDelegate {
    /// `target=_blank` — load in the same webview (no popup windows on iOS).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if let nodeHost = connection.baseURL.host, url.host == nodeHost {
                webView.load(navigationAction.request)
            } else {
                externalURL = url
            }
        }
        return nil
    }
}

extension DashboardModel: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: dest)
        return dest
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        lastError = "Download failed: \(error.localizedDescription)"
    }
}

/// SwiftUI wrapper: hosts the model's webview and wires pull-to-refresh.
struct WebDashboardView: UIViewRepresentable {
    @ObservedObject var model: DashboardModel

    func makeUIView(context: Context) -> WKWebView {
        let webView = model.webView
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.handleRefresh(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.refresh = refresh
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // End the refresh spinner when loading finishes.
        if !model.isLoading { context.coordinator.refresh?.endRefreshing() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator {
        let model: DashboardModel
        weak var refresh: UIRefreshControl?
        init(model: DashboardModel) { self.model = model }
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            MainActor.assumeIsolated { model.reload() }
        }
    }
}
