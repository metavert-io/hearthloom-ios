import SwiftUI

/// The capture field the control opens: keyboard up, one button. It is shown
/// over whatever the app is on — including the Face ID lock screen — because it
/// only ever writes: it uses the capture-only key and shows nothing from the
/// node. `connection` is passed when the app happens to be unlocked.
struct QuickCaptureSheet: View {
    let connection: Connection?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    private var canSave: Bool {
        !saving && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A thought, a task, a reminder…", text: $draft, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier("quickcapture.field")
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Saved on this iPhone first, then uploaded to your node.")
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).bold().disabled(!canSave)
                        .accessibilityIdentifier("quickcapture.save")
                }
            }
            .tint(HearthTheme.accent)
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        error = nil; saving = true
        let text = draft, connection = connection
        Task {
            do {
                try await CaptureService.shared.capture(text: text)
                // Queued is saved; the upload carries on after the sheet closes.
                Task { await CaptureService.shared.drain(force: true, connection: connection) }
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                saving = false
            }
        }
    }
}
