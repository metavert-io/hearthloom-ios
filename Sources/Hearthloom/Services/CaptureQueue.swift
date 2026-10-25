import Foundation

/// One captured thought waiting to upload. `clientRef` is the server's dedupe
/// key (`client_ref`), so a retried upload never files twice; `capturedAt` is
/// when the user captured it, not when it uploaded.
struct CaptureItem: Codable, Equatable {
    let clientRef: String
    let text: String
    let capturedAt: String
    var lat: Double?
    var lon: Double?

    init(clientRef: String = UUID().uuidString, text: String, capturedAt: Date = Date(),
         lat: Double? = nil, lon: Double? = nil) {
        self.clientRef = clientRef
        self.text = text
        self.capturedAt = HearthAPI.rfc3339(capturedAt)
        self.lat = lat
        self.lon = lon
    }
}

/// Offline queue for captures: append first, upload later. A JSON file rather
/// than UserDefaults so it can carry an explicit data-protection class — the
/// capture intent runs from Siri/Shortcuts while the phone is locked, so the
/// file must be writable after first unlock (the default for app files, set
/// explicitly here so it can't regress). The intent and the app share one
/// process, so a lock suffices — no App Group. `fileURL` is injectable for tests.
final class CaptureQueue: @unchecked Sendable {
    static let shared = CaptureQueue(fileURL: defaultURL)

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) { self.fileURL = fileURL }

    private static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("capture-queue.json")
    }

    /// Queue an item. A repeat of a `clientRef` already queued is ignored.
    func append(_ item: CaptureItem) throws {
        try lock.withLock {
            var items = read()
            guard !items.contains(where: { $0.clientRef == item.clientRef }) else { return }
            items.append(item)
            try write(items)
        }
    }

    /// Queued items, oldest first.
    func all() -> [CaptureItem] { lock.withLock { read() } }

    var count: Int { all().count }

    func remove(clientRef: String) {
        lock.withLock {
            let items = read().filter { $0.clientRef != clientRef }
            try? write(items)
        }
    }

    private func read() -> [CaptureItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([CaptureItem].self, from: data) else { return [] }
        return items
    }

    private func write(_ items: [CaptureItem]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(items)
            .write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
