import SwiftUI

/// The Connect screen. Self-hosting comes first: pair with your Hearthloom's QR
/// code, or enter its address — credential fields (that node's email +
/// password, or a device token) appear only once the app has reached it. A
/// hosted provider is listed further down and never preselected; choosing it
/// runs that provider's account flow. One `LoginFlow` drives every step.
struct ConnectView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var flow = LoginFlow()
    @State private var showScanner = false
    private let listedProvider = HostedProvider.listed

    var body: some View {
        ZStack {
            HearthTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    header
                    Group {
                        switch flow.step {
                        case .start:          start
                        case .serverAddress:  serverAddressForm
                        case .serverSignIn:   serverSignInForm
                        case .pasteToken:     pasteForm
                        case .providerSignIn: providerSignInForm
                        case .createForm:     createForm
                        case .mfa:            mfaForm
                        case .chooseTenant:   tenantList
                        case .chooseInstance: instanceList
                        case .working:        workingView
                        }
                    }
                    if let status = flow.status, flow.step != .working {
                        note(status, systemImage: "info.circle")
                    }
                    if let error = flow.error {
                        note(error, systemImage: "exclamationmark.triangle", color: .red)
                            .accessibilityIdentifier("connect.error")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { flow.bind(app) }
        .fullScreenCover(isPresented: $showScanner) { scanner }
        .tint(HearthTheme.accent)
    }

    // MARK: - Pairing QR scanner

    private var scanner: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if QRScannerView.isAvailable {
                QRScannerView(onScan: handleScan).ignoresSafeArea()
            } else {
                Text("This device can’t scan QR codes. Enter your server address and a device token instead.")
                    .font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(40)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showScanner = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title).foregroundStyle(.white.opacity(0.9))
                    }.padding()
                }
                Spacer()
                Text("Point at the pairing QR in your dashboard → Integrations → Pair a device")
                    .font(.footnote).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 44).padding(.horizontal, 24)
            }
        }
    }

    private func handleScan(_ raw: String) {
        showScanner = false
        if let pairing = PairingPayload.parse(raw) {
            flow.connectWithPairing(url: pairing.url, pat: pairing.pat)
        } else {
            flow.error = "That QR code isn’t a Hearthloom pairing code."
        }
    }

    private func scanPairingCode() { flow.error = nil; showScanner = true }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.system(size: 52)).foregroundStyle(HearthTheme.accent)
            Text("Hearthloom").font(.largeTitle.bold())
            if flow.step == .start {
                Text("Connect this iPhone to your Hearthloom")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Start: pair · server address · hosted providers

    private var start: some View {
        VStack(spacing: 14) {
            primaryButton("Pair with your Hearthloom (QR)", systemImage: "qrcode.viewfinder") {
                scanPairingCode()
            }
            .accessibilityIdentifier("connect.pairqr")
            footnote("In your Hearthloom’s dashboard, open Integrations → Pair a device.")

            secondaryButton("Enter server address", systemImage: "server.rack") {
                flow.enterServerAddress()
            }
            .accessibilityIdentifier("connect.address")
            .padding(.top, 8)
            footnote("Then sign in with that server’s account, or use a device token.")

            if let hosted = listedProvider {
                VStack(spacing: 10) {
                    Text("Hosted providers")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    rowButton(hosted.name, subtitle: hosted.url.host) { flow.chooseHosted(hosted) }
                        .accessibilityIdentifier("connect.provider")
                    footnote("A hosted provider runs a Hearthloom for you. Sign in, or create an account with them.")
                }
                .padding(.top, 30)
            }
        }
    }

    // MARK: - Your server

    private var serverAddressForm: some View {
        VStack(spacing: 14) {
            sectionTitle("Your Hearthloom’s address")
            field("https://node.example.com or http://192.168.1.20:43278",
                  text: $flow.serverAddress, keyboard: .URL)
                .accessibilityIdentifier("server.address")
                .submitLabel(.continue)
                .onSubmit { if flow.canContinueToServer { flow.confirmServer() } }
            primaryButton(flow.working ? "Connecting…" : "Continue") { flow.confirmServer() }
                .disabled(!flow.canContinueToServer || flow.working)
                .accessibilityIdentifier("server.continue")
            footnote("http:// works only for local addresses (like 192.168.1.20 or mynode.local). Anything else needs https://.")
            secondaryLink("Scan a pairing QR instead") { scanPairingCode() }
            backLink()
        }
    }

    private var serverSignInForm: some View {
        VStack(spacing: 14) {
            serverChip
            sectionTitle("Sign in to this Hearthloom")
            field("Email", text: $flow.email, keyboard: .emailAddress)
                .accessibilityIdentifier("login.email")
            secureField("Password", text: $flow.password)
                .accessibilityIdentifier("login.password")
            primaryButton(flow.working ? "Signing in…" : "Sign in") { flow.signIn() }
                .disabled(!flow.canSignIn || flow.working)
                .accessibilityIdentifier("login.signin")
            footnote("Uses this server’s own account, then keeps a device token for this iPhone behind \(BiometricGate.biometryName).")
            Divider().padding(.vertical, 6)
            secondaryLink("Use a device token instead") { flow.useDeviceToken() }
                .accessibilityIdentifier("login.usetoken")
            backLink()
        }
    }

    private var pasteForm: some View {
        VStack(spacing: 14) {
            serverChip
            sectionTitle("Connect with a device token")
            field("Device token (hl_…)", text: $flow.pasteToken, mono: true)
                .accessibilityIdentifier("token.value")
            primaryButton(flow.working ? "Connecting…" : "Connect") { flow.connectWithToken() }
                .disabled(!flow.canPaste || flow.working)
                .accessibilityIdentifier("token.connect")
            footnote("Mint one on the server with `hearthloom key mint --scopes read,ingest,notify`.")
            secondaryLink("Scan a pairing QR instead") { scanPairingCode() }
            backLink()
        }
    }

    /// The server the credentials are for, with a way to change it.
    private var serverChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.footnote).foregroundStyle(.secondary)
            Text(flow.serverURL?.host ?? flow.serverAddress)
                .font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Change") { flow.changeServer() }
                .font(.footnote)
                .accessibilityIdentifier("server.change")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(HearthTheme.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Hosted provider

    private var providerName: String { flow.hostedProvider?.name ?? "the provider" }

    private var providerSignInForm: some View {
        VStack(spacing: 14) {
            sectionTitle("Sign in to \(providerName)")
            field("Email", text: $flow.email, keyboard: .emailAddress)
                .accessibilityIdentifier("provider.email")
            secureField("Password", text: $flow.password)
                .accessibilityIdentifier("provider.password")
            primaryButton(flow.working ? "Signing in…" : "Sign in") { flow.signIn() }
                .disabled(!flow.canSignIn || flow.working)
                .accessibilityIdentifier("provider.signin")
            footnote("\(providerName) runs your Hearthloom. Once you’re signed in, this iPhone connects to that Hearthloom directly.")
            Divider().padding(.vertical, 6)
            secondaryLink("New to \(providerName)? Create an account") { flow.createAccountInstead() }
                .accessibilityIdentifier("provider.create")
            backLink()
        }
    }

    private var createForm: some View {
        VStack(spacing: 14) {
            sectionTitle("Create a \(providerName) account")
            field("Email", text: $flow.email, keyboard: .emailAddress)
            secureField("Password", text: $flow.password)
            field("Display name", text: $flow.displayName)
            field("Name your brain (e.g. my-brain)", text: $flow.instanceName)
            primaryButton(flow.working ? "Creating…" : "Create my Hearthloom") { flow.createAccount() }
                .disabled(!flow.canCreate || flow.working)
            backLink()
        }
    }

    // MARK: - MFA

    private var mfaForm: some View {
        VStack(spacing: 14) {
            sectionTitle("Two-factor code")
            field("6-digit code", text: $flow.mfaCode, keyboard: .numberPad)
            primaryButton(flow.working ? "Verifying…" : "Verify") { flow.submitMFA() }
                .disabled(flow.mfaCode.count < 6 || flow.working)
            backLink()
        }
    }

    // MARK: - Pickers

    private var tenantList: some View {
        VStack(spacing: 10) {
            sectionTitle("Choose a workspace")
            ForEach(flow.tenants) { t in
                rowButton(t.tenantName.isEmpty ? t.tenantSlug : t.tenantName,
                          trailing: t.isRoot ? "root" : nil) { flow.selectTenant(t.tenantId) }
            }
            backLink()
        }
    }

    private var instanceList: some View {
        VStack(spacing: 10) {
            sectionTitle("Choose a Hearthloom")
            ForEach(flow.instances) { inst in
                rowButton(inst.name, subtitle: inst.status) { flow.selectInstance(inst.id) }
                    .disabled(!inst.ready)
            }
            backLink()
        }
    }

    private var workingView: some View {
        VStack(spacing: 14) {
            ProgressView().tint(HearthTheme.accent)
            Text(flow.status ?? "Working…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: - Reusable bits

    private func field(_ placeholder: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default, mono: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .keyboardType(keyboard)
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .padding(14)
            .background(HearthTheme.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(14)
            .background(HearthTheme.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func primaryButton(_ title: String, systemImage: String? = nil,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if flow.working {
                    ProgressView().tint(.white).padding(.trailing, 4)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent).tint(HearthTheme.accent)
    }

    private func secondaryButton(_ title: String, systemImage: String,
                                 _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.bordered).tint(HearthTheme.accent)
    }

    private func secondaryLink(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.subheadline)
    }

    private func backLink() -> some View {
        Button { flow.back() } label: {
            Label("Back", systemImage: "chevron.left").font(.subheadline)
        }
        .padding(.top, 4)
        .accessibilityIdentifier("connect.back")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footnote(_ t: LocalizedStringKey) -> some View {
        Text(t).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowButton(_ title: String, subtitle: String? = nil, trailing: String? = nil,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let trailing { Text(trailing).font(.caption2).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(HearthTheme.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String, systemImage: String, color: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
