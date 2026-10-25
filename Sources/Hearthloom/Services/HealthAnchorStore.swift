import Foundation
import HealthKit

/// Persists `HKQueryAnchor`s per HealthKit type so incremental
/// `HKAnchoredObjectQuery` runs pick up exactly where the last one left off —
/// native partial updates, no re-scan. Anchors are opaque `Data` (NSSecureCoding);
/// the raw Data layer is unit-testable without HealthKit.
struct HealthAnchorStore {
    private let defaults: UserDefaults
    private let prefix = "hk.anchor."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: - Raw Data layer (testable)

    func data(for key: String) -> Data? { defaults.data(forKey: prefix + key) }

    func setData(_ data: Data?, for key: String) {
        if let data { defaults.set(data, forKey: prefix + key) }
        else { defaults.removeObject(forKey: prefix + key) }
    }

    func clearAll(keys: [String]) { keys.forEach { setData(nil, for: $0) } }

    // MARK: - HKQueryAnchor convenience

    func anchor(for key: String) -> HKQueryAnchor? {
        guard let data = data(for: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func setAnchor(_ anchor: HKQueryAnchor?, for key: String) {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor,
                                                           requiringSecureCoding: true) else {
            setData(nil, for: key); return
        }
        setData(data, for: key)
    }
}
