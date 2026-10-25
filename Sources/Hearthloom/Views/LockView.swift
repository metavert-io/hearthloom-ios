import SwiftUI

/// Face ID app-open gate. Shown when a stored connection exists but the token
/// hasn't been unlocked this foreground session.
struct LockView: View {
    @EnvironmentObject var app: AppState
    @State private var authenticating = false

    var body: some View {
        ZStack {
            HearthTheme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(HearthTheme.accent)
                Text("Hearthloom")
                    .font(.largeTitle.bold())
                Text("Locked")
                    .foregroundStyle(.secondary)

                if let err = app.unlockError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task { authenticating = true; await app.unlock(); authenticating = false }
                } label: {
                    Label("Unlock with \(BiometricGate.biometryName)",
                          systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(HearthTheme.accent)
                .disabled(authenticating)
                .padding(.horizontal, 40)
            }
        }
        .task {
            // Auto-prompt once on appear.
            if app.unlockError == nil { await app.unlock() }
        }
    }
}
