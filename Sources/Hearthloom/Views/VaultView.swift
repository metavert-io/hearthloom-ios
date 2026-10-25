import SwiftUI

/// Face ID-gated vault control. Unlocking sends `POST /v1/vault {action:"unlock"}`
/// to the node (approved from mobile). Private data is never persisted on device;
/// unlock is transient and time-boxed server-side.
struct VaultView: View {
    let connection: Connection
    @ObservedObject var vault: VaultStatus
    @State private var minutes = 15
    @State private var working = false
    @State private var status: String?
    @State private var error: String?

    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    private var actor: String { "human:\(connection.displayName)" }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(vault.locked ? "Vault locked" : "Vault unlocked",
                          systemImage: vault.locked ? "lock.shield" : "lock.open.fill")
                        .font(.headline)
                        .foregroundStyle(vault.locked ? Color.primary : HearthTheme.accent)
                    if !vault.locked && vault.secondsRemaining > 0 {
                        Text("Unlocked — relocks in about \(max(1, vault.secondsRemaining / 60)) min.")
                            .font(.footnote).foregroundStyle(HearthTheme.accent)
                    }
                    Text("Unlocking reveals `scope='private'` data on the node for a limited window. It never leaves the node and is never stored on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }

            Section("Unlock window") {
                Stepper("\(minutes) minutes", value: $minutes, in: 1...60)
            }

            if let status { Section { Label(status, systemImage: "checkmark.circle").font(.footnote) } }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await run(action: "unlock") }
                } label: {
                    HStack {
                        if working { ProgressView().padding(.trailing, 6) }
                        Label("Unlock with \(BiometricGate.biometryName)", systemImage: "faceid")
                    }.frame(maxWidth: .infinity)
                }
                .disabled(working)

                Button(role: .destructive) {
                    Task { await run(action: "lock") }
                } label: {
                    Label("Lock now", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)
            }
        }
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
        .task { await vault.refresh() }
    }

    private func run(action: String) async {
        error = nil; status = nil; working = true
        defer { working = false }
        do {
            // Separate Face ID gate specifically for the vault action.
            _ = try await BiometricGate.evaluate(
                reason: action == "unlock" ? "Unlock your private vault"
                                           : "Lock your private vault")
            let result = try await api.setVault(pat: connection.deviceToken, action: action,
                                                minutes: minutes, actor: actor)
            vault.apply(result)   // updates the shared state → tab icon flips
            status = action == "unlock"
                ? "Vault unlocked for \(minutes) minutes."
                : "Vault locked."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
