import Foundation
import SwiftUI
import UIKit

/// Where the credentials go: a node you entered (and the app reached), or a
/// hosted provider's accounts.
enum LoginProvider: Equatable {
    case selfHost(URL)
    case hosted(HostedProvider)

    var label: String {
        switch self {
        case .selfHost(let u): return u.host ?? u.absoluteString
        case .hosted(let p): return p.name
        }
    }
}

/// One engine behind the Connect screen. Self-hosting comes first: pair with
/// your node's QR code, or enter its address and then that node's email +
/// password or a device token. A hosted provider is a listed alternative,
/// never the default; choosing one runs its account flow (sign in or create an
/// account, TOTP, workspace, node). Pauses at decision points by publishing a
/// `step`.
@MainActor
final class LoginFlow: ObservableObject {
    enum Step: Equatable {
        case start            // pair (QR) · enter a server address · hosted providers
        case serverAddress    // your node's address
        case serverSignIn     // node reached: its email + password
        case pasteToken       // node reached: a device token
        case providerSignIn   // hosted provider: account sign-in
        case createForm       // hosted provider: new account + node
        case mfa              // hosted provider: TOTP code
        case chooseTenant     // hosted provider: workspace picker
        case chooseInstance   // hosted provider: node picker
        case working
    }

    @Published var step: Step = .start
    /// nil until you choose: a server you entered and the app reached, or a
    /// hosted provider. Never preset.
    @Published private(set) var provider: LoginProvider?

    // the address you're typing
    @Published var serverAddress = ""

    // shared credential fields
    @Published var email = ""
    @Published var password = ""
    @Published var mfaCode = ""

    // create-account fields (hosted provider)
    @Published var displayName = ""
    @Published var instanceName = ""

    // a device token for the reached server
    @Published var pasteToken = ""

    @Published var working = false
    @Published var status: String?
    @Published var error: String?
    @Published var tenants: [HostedProviderClient.Membership] = []
    @Published var instances: [HostedProviderClient.InstanceSummary] = []

    private weak var app: AppState?
    private var session: HostedProviderClient.AuthSession?
    private var mfaToken = ""
    private var tenantId = ""
    private var isCreate = false

    func bind(_ app: AppState) { self.app = app }

    /// The node you're connecting to directly, once the app has reached it.
    var serverURL: URL? { if case .selfHost(let u) = provider { return u }; return nil }
    /// The hosted provider you chose, if any.
    var hostedProvider: HostedProvider? { if case .hosted(let p) = provider { return p }; return nil }

    var canContinueToServer: Bool { HearthAPI.normalize(serverAddress) != nil }
    var canSignIn: Bool { !email.isEmpty && !password.isEmpty }
    var canCreate: Bool {
        canSignIn && !instanceName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var canPaste: Bool {
        serverURL != nil && !pasteToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static var deviceName: String { UIDevice.current.name }

    // MARK: - Choosing where to connect

    func enterServerAddress() { clearMessages(); step = .serverAddress }

    /// Reach the typed address (`GET /health`) before asking for credentials,
    /// so a wrong address fails here rather than after a password.
    func confirmServer() {
        guard let url = HearthAPI.normalize(serverAddress) else {
            error = HearthAPI.APIError.badBaseURL.errorDescription; return
        }
        run {
            self.status = "Looking for your Hearthloom at \(url.host ?? "that address")…"
            try await HearthAPI(baseURL: url).probeHealth()
            self.provider = .selfHost(url)
            self.status = nil
            self.step = .serverSignIn
        }
    }

    /// Back to the address field (from either credential form).
    func changeServer() { clearMessages(); provider = nil; step = .serverAddress }

    func useDeviceToken() { clearMessages(); step = .pasteToken }

    func chooseHosted(_ hosted: HostedProvider) {
        clearMessages()
        provider = .hosted(hosted)
        step = .providerSignIn
    }

    func createAccountInstead() { clearMessages(); step = .createForm }

    // MARK: - Sign in

    func signIn() {
        isCreate = false
        switch provider {
        case .selfHost(let url)?: signInToNode(url)
        case .hosted(let hosted)?: signInToProvider(hosted)
        case nil: step = .start
        }
    }

    /// The node's own account: `POST /v1/auth/login`, then mint a device token.
    private func signInToNode(_ url: URL) {
        run {
            self.status = "Signing in and creating a device token…"
            let r = try await HearthAPI(baseURL: url).signInAndMintKey(
                email: self.email, password: self.password, deviceName: Self.deviceName)
            let conn = Connection(baseURL: url, deviceToken: r.deviceToken,
                                  displayName: url.host ?? "Hearthloom", origin: .selfHostSignIn)
            try self.app?.adopt(conn, sessionCookies: r.sessionCookies)
        }
    }

    private func signInToProvider(_ hosted: HostedProvider) {
        run {
            self.status = "Signing in…"
            switch try await HostedProviderClient(base: hosted.url)
                .login(email: self.email, password: self.password) {
            case .authenticated(let s): try await self.afterAuth(s)
            case .mfaRequired(let t): self.mfaToken = t; self.status = nil; self.step = .mfa
            }
        }
    }

    // MARK: - Create (hosted provider only)

    func createAccount() {
        isCreate = true
        run {
            self.status = "Creating your account…"
            let s = try await self.providerClient().register(
                email: self.email, password: self.password, displayName: self.displayName)
            try await self.afterAuth(s)
        }
    }

    // MARK: - Device token

    /// Connect to the reached server with a device token minted on the node.
    func connectWithToken() {
        guard let url = serverURL else { changeServer(); return }
        connect(url: url, token: pasteToken)
    }

    /// Connect from a scanned pairing QR (`hearthloom://pair?url=…&pat=…`): the
    /// code names the node and carries a device token for it.
    func connectWithPairing(url: URL, pat: String) {
        connect(url: url, token: pat)
    }

    /// Validate-then-adopt: the node answers `/health`, and the token
    /// authorizes a real read.
    private func connect(url: URL, token raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        run {
            self.status = "Checking the device token…"
            let api = HearthAPI(baseURL: url)
            try await api.probeHealth()
            try await api.validatePAT(token)
            let conn = Connection(baseURL: url, deviceToken: token,
                                  displayName: url.host ?? "Hearthloom", origin: .selfHostPastedPAT)
            try self.app?.adopt(conn)
        }
    }

    // MARK: - Hosted provider: branch resumption

    func submitMFA() {
        run {
            self.status = "Verifying…"
            let s = try await self.providerClient().mfaChallenge(mfaToken: self.mfaToken, code: self.mfaCode)
            try await self.afterAuth(s)
        }
    }

    func selectTenant(_ id: String) { tenantId = id; run { try await self.afterTenant() } }
    func selectInstance(_ id: String) { run { try await self.openAndFinish(instanceId: id) } }

    // MARK: - Hosted provider stages

    private func providerClient() throws -> HostedProviderClient {
        guard let hosted = hostedProvider else {
            throw HostedProviderClient.ProviderError.decoding("no provider chosen")
        }
        return HostedProviderClient(base: hosted.url)
    }

    private func afterAuth(_ session: HostedProviderClient.AuthSession) async throws {
        self.session = session
        if session.memberships.count > 1 {
            tenants = session.memberships; status = nil; step = .chooseTenant; return
        }
        guard let tenant = session.defaultTenant else { throw HostedProviderClient.ProviderError.noTenant }
        tenantId = tenant.tenantId
        try await afterTenant()
    }

    private func afterTenant() async throws {
        let client = try providerClient()
        guard let session else { throw HostedProviderClient.ProviderError.noTenant }
        let auth = HostedProviderClient.Auth(accessToken: session.accessToken, tenantId: tenantId)
        if isCreate {
            step = .working
            status = "Creating your Hearthloom…"
            let id = try await client.provision(name: instanceName, auth: auth)
            try await waitReady(id: id, auth: auth, client: client)
            try await openAndFinish(instanceId: id)
        } else {
            status = "Finding your Hearthloom…"
            let ready = try await client.listInstances(auth: auth)
                .filter { $0.ready || !$0.status.isEmpty }
            if ready.isEmpty { throw HostedProviderClient.ProviderError.noInstance }
            if ready.count == 1 { try await openAndFinish(instanceId: ready[0].id) }
            else { instances = ready; status = nil; step = .chooseInstance }
        }
    }

    private func waitReady(id: String, auth: HostedProviderClient.Auth,
                           client: HostedProviderClient) async throws {
        for _ in 0..<90 {
            let (ready, _) = try await client.instance(id: id, auth: auth)
            if ready { return }
            status = "Creating your Hearthloom… (this can take a minute)"
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    /// Get a one-time login token from the provider, then sign in to the node
    /// itself and mint this iPhone's device token there.
    private func openAndFinish(instanceId: String) async throws {
        let client = try providerClient()
        guard let session else { throw HostedProviderClient.ProviderError.noTenant }
        let auth = HostedProviderClient.Auth(accessToken: session.accessToken, tenantId: tenantId)
        step = .working
        status = "Opening your Hearthloom…"
        let opened = try await client.open(id: instanceId, auth: auth)
        let api = HearthAPI(baseURL: opened.url)
        try await api.probeHealth()
        status = "Creating a device token…"
        let name = instanceName.isEmpty ? "Hearthloom" : instanceName
        let result = try await api.signInWithIssuerTokenAndMintKey(
            issuerToken: opened.issuerToken, deviceName: displayName.isEmpty ? Self.deviceName : displayName)
        let origin: Connection.Origin = isCreate ? .hostedNew : .hostedSignIn
        let conn = Connection(baseURL: opened.url, deviceToken: result.deviceToken,
                              displayName: name, origin: origin)
        try app?.adopt(conn, sessionCookies: result.sessionCookies)
    }

    // MARK: - Runner + navigation

    /// One step back along the path you came.
    func back() {
        clearMessages()
        switch step {
        case .start, .serverAddress, .providerSignIn, .working:
            provider = nil; step = .start
        case .serverSignIn:
            changeServer()
        case .pasteToken:
            step = .serverSignIn
        case .createForm, .mfa, .chooseTenant, .chooseInstance:
            mfaCode = ""; step = .providerSignIn
        }
    }

    private func clearMessages() { error = nil; status = nil }

    /// Run one network step. On failure, show the error and return to the
    /// screen the step started from.
    private func run(_ body: @escaping () async throws -> Void) {
        let origin = step
        error = nil; working = true
        Task {
            defer { working = false }
            do { try await body() }
            catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status = nil
                if self.step == .working { self.step = origin }
            }
        }
    }
}
