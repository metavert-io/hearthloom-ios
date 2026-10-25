import Combine
import SwiftUI

/// Observable view of capture's persisted state. The intent can change that
/// state with no UI running, so this re-reads on `CaptureStatus.changed`.
@MainActor
final class CaptureModel: ObservableObject {
    @Published private(set) var queued = 0
    @Published private(set) var uploaded = 0
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastDropped: String?
    @Published private(set) var hasKey = false
    @Published private(set) var keyRejected = false
    @Published private(set) var endpointUnavailable = false
    @Published var busy = false

    private var observer: AnyCancellable?

    init() {
        refresh()
        observer = NotificationCenter.default.publisher(for: CaptureStatus.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let status = CaptureStatus()
        queued = CaptureQueue.shared.count
        uploaded = status.uploadedCount
        lastUploadAt = status.lastUploadAt
        lastError = status.lastError
        lastDropped = status.lastDropped
        hasKey = CaptureKeyStore.load() != nil
        keyRejected = status.keyRejected
        endpointUnavailable = status.endpointUnavailable
    }

    var keyText: String {
        if keyRejected { return "Rejected by the node" }
        if hasKey { return "Ready" }
        return endpointUnavailable ? "Not available on this node yet" : "Not created"
    }

    /// Trailing text for the Settings row.
    var rowStatus: String {
        if keyRejected { return "Needs attention" }
        return queued > 0 ? "\(queued) queued" : (hasKey ? "Ready" : "")
    }
}

/// Detail screen for one-tap capture: what's queued, when it last uploaded, the
/// capture key, and a field to capture from inside the app. Errors are inline.
struct CaptureView: View {
    let connection: Connection
    @ObservedObject var model: CaptureModel
    @State private var draft = ""
    @State private var inputError: String?
    @State private var keyError: String?
    @FocusState private var composing: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Quick capture", systemImage: "square.and.pencil").font(.headline)
                    Text("Get a thought into Hearthloom without opening the app. It’s filed as a task or a note, saved on this iPhone first, and uploaded when your node is reachable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }

            Section {
                TextField("A thought, a task, a reminder…", text: $draft, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($composing)
                    .accessibilityIdentifier("capture.field")
                Button {
                    save()
                } label: {
                    Label("Capture", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("capture.save")
                if let inputError {
                    Label(inputError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Status") {
                LabeledContent("Uploading to", value: connection.baseURL.host ?? "—")
                LabeledContent("Queued on this iPhone", value: "\(model.queued)")
                    .accessibilityIdentifier("capture.queued")
                LabeledContent("Last upload", value: DeviceSync.relative(model.lastUploadAt))
                LabeledContent("Uploaded", value: "\(model.uploaded)")
                    .accessibilityIdentifier("capture.uploaded")
                LabeledContent("Capture key", value: model.keyText)
                if model.endpointUnavailable {
                    Label("This node doesn’t support capture yet. Captures stay queued here and upload once it does.",
                          systemImage: "clock.badge").font(.footnote).foregroundStyle(.secondary)
                }
                if model.keyRejected {
                    Label("The capture key was rejected. Re-create it below; anything queued will then upload.",
                          systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                if let err = model.lastError, !model.keyRejected {
                    Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
                if let dropped = model.lastDropped {
                    Label("A capture was refused by the node and discarded: \(dropped)",
                          systemImage: "trash").font(.footnote).foregroundStyle(.secondary)
                }
                if let keyError {
                    Label(keyError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button { upload() } label: {
                    HStack {
                        if model.busy { ProgressView().padding(.trailing, 6) }
                        Label(model.busy ? "Uploading…" : "Upload now", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(model.busy || model.queued == 0)
                Button { remint() } label: {
                    Label(model.hasKey ? "Re-create capture key" : "Create capture key", systemImage: "key")
                }
                .disabled(model.busy)
            } footer: {
                Text("The capture key can only add captures — it can’t read anything from your node — so it can be used while this iPhone is locked. Re-creating it doesn’t revoke the old one; do that in the dashboard’s **API Keys** list.")
            }

            CaptureSetupSection()
        }
        .navigationTitle("Quick capture")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { model.refresh() }
    }

    private func save() {
        inputError = nil
        composing = false
        let text = draft
        Task {
            do {
                try await CaptureService.shared.capture(text: text)
                draft = ""
                await CaptureService.shared.drain(force: true, connection: connection)
            } catch {
                inputError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func upload() {
        model.busy = true
        Task {
            await CaptureService.shared.drain(force: true, connection: connection)
            model.busy = false
        }
    }

    private func remint() {
        model.busy = true; keyError = nil
        Task {
            keyError = await CaptureService.shared.ensureKey(connection: connection, force: true)
            await CaptureService.shared.drain(force: true, connection: connection)
            model.busy = false
        }
    }
}
