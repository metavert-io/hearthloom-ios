import SwiftUI

/// Native re-auth for the embedded dashboard, for when its session has expired
/// and couldn't be renewed silently from the stored device token
/// (`POST /v1/auth/session-from-key`, which `DashboardModel.start` tries
/// first). Face ID-gated, then re-establishes `hl_session` with the node's
/// email + password and reloads the webview.
struct ReconnectSheet: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The dashboard needs a fresh sign-in on this node. Your device token stays in place for native actions — this only refreshes the in-app browser session.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sign in") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            if working { ProgressView().padding(.trailing, 6) }
                            Label("Reconnect with \(BiometricGate.biometryName)", systemImage: "faceid")
                        }.frame(maxWidth: .infinity)
                    }
                    .disabled(working || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Reconnect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .tint(HearthTheme.accent)
        }
    }

    private func submit() {
        error = nil; working = true
        Task {
            defer { working = false }
            do {
                _ = try await BiometricGate.evaluate(reason: "Reconnect the dashboard session")
                try await model.reauthenticate(email: email, password: password)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
