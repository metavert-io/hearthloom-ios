import SwiftUI

/// Detail screen for the Vision-scan feature: pick a document type, capture with
/// the system scanner, and the recognized text streams to the node. User-driven,
/// so there is no "connect" toggle — just Scan.
struct ScanView: View {
    let host: String
    @ObservedObject var ingest: VisionScanIngest
    @State private var kind: ScanKind = .receipt
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Scan documents", systemImage: "doc.viewfinder").font(.headline)
                    Text("Capture receipts, business cards, or documents. Only the recognized text is sent to your node — never the images.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }

            Section("Type") {
                Picker("Type", selection: $kind) {
                    ForEach(ScanKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    showScanner = true
                } label: {
                    HStack {
                        if ingest.busy { ProgressView().padding(.trailing, 6) }
                        Label(ingest.busy ? "Reading…" : "Scan \(kind.title)", systemImage: "camera.viewfinder")
                    }.frame(maxWidth: .infinity)
                }
                .disabled(ingest.busy)
            }

            Section("Status") {
                LabeledContent("Streaming to", value: host)
                LabeledContent("Last scanned", value: DeviceSync.relative(ingest.lastSyncedAt))
                LabeledContent("Scans sent", value: "\(ingest.scannedCount)")
                if let err = ingest.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }

            if let text = ingest.lastText, !text.isEmpty {
                Section("Last capture") {
                    Text(text).font(.footnote.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(8)
                }
            }
        }
        .navigationTitle("Scan documents")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HearthTheme.accent)
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(
                onScan: { images in
                    showScanner = false
                    Task { await ingest.ingest(images: images, kind: kind) }
                },
                onCancel: { showScanner = false })
            .ignoresSafeArea()
        }
    }
}
