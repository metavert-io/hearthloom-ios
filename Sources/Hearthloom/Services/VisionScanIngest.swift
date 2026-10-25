import Foundation
import UIKit
import Vision

/// Vision-scan feature (Track B, **user-driven**) → `POST /v1/ingest/scan`. Unlike
/// the streaming adapters this fires only when the user captures a document: pages
/// are OCR'd on device with the Vision framework and the recognized text is sent
/// (never the images). Idempotent per capture by a timestamped key.
enum ScanKind: String, CaseIterable, Identifiable {
    case receipt, card, document
    var id: String { rawValue }
    var title: String {
        switch self {
        case .receipt: return "Receipt"
        case .card: return "Business card"
        case .document: return "Document"
        }
    }
}

struct ScanRecord: Codable, Equatable {
    let key: String
    let kind: String
    let ocrText: String
    let capturedAt: String
    let tzOffsetMinutes: Int
}

enum ScanPayload {
    static func build(actor: String, items: [ScanRecord]) -> [String: Any] {
        ["actor": actor, "source": "ios-scan",
         "items": items.map { s -> [String: Any] in
            ["key": s.key, "kind": s.kind, "ocr_text": s.ocrText,
             "captured_at": s.capturedAt, "tz_offset_minutes": s.tzOffsetMinutes] }]
    }
}

enum ScanIngestConfig { static let streamingEnabled = true }

@MainActor
final class VisionScanIngest: ObservableObject {
    @Published private(set) var scannedCount =
        UserDefaults.standard.integer(forKey: "scan.count")
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastText: String?    // preview of the most recent capture
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "scan.lastSyncedAt") as? Date

    private let connection: Connection
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    init(connection: Connection) { self.connection = connection }

    /// OCR the captured pages off the main thread, then stream the text.
    func ingest(images: [UIImage], kind: ScanKind) async {
        busy = true; lastError = nil; defer { busy = false }
        let text = await Task.detached(priority: .userInitiated) {
            images.map { Self.recognizeText(in: $0) }.joined(separator: "\n\n")
        }.value
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { lastError = "No readable text found in the capture."; return }

        let now = Date()
        let rec = ScanRecord(
            key: "scan|\(Int(now.timeIntervalSince1970))|\(kind.rawValue)",
            kind: kind.rawValue, ocrText: trimmed,
            capturedAt: HearthAPI.rfc3339(now),
            tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60)
        do {
            if ScanIngestConfig.streamingEnabled {
                let api = self.api, pat = connection.deviceToken
                let body = ScanPayload.build(actor: "adapter:ios-scan", items: [rec])
                _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/scan", pat: pat, body: body) }
            }
            scannedCount += 1
            lastText = trimmed
            lastSyncedAt = now
            UserDefaults.standard.set(scannedCount, forKey: "scan.count")
            UserDefaults.standard.set(now, forKey: "scan.lastSyncedAt")
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Vision OCR (accurate, language-corrected) for a single page.
    nonisolated static func recognizeText(in image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
