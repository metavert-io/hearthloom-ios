import Foundation

/// A single Focus transition captured by the Focus-filter App Intent. `on` marks
/// activation (with the user's `mode` label from the filter config) vs
/// deactivation. Persisted in UserDefaults so the intent (which runs in a
/// background app launch and can't reach the biometric-gated device token) can
/// hand events to `FocusIngest`, which drains and uploads them when foregrounded.
struct FocusEvent: Codable, Equatable {
    let on: Bool
    let mode: String
    let at: Date
}

/// Append-only queue of `FocusEvent`s shared between the App Intent (writer) and
/// `FocusIngest` (drainer). Both run in the main app process, so plain
/// UserDefaults suffices — no App Group needed. `defaults` is injectable for tests.
enum FocusEventStore {
    static let key = "focus.events"

    static func append(_ event: FocusEvent, defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        events.append(event)
        save(events, defaults: defaults)
    }

    /// Return the queued events in chronological order and clear the queue.
    static func drain(defaults: UserDefaults = .standard) -> [FocusEvent] {
        let events = load(defaults: defaults).sorted { $0.at < $1.at }
        defaults.removeObject(forKey: key)
        return events
    }

    static func load(defaults: UserDefaults = .standard) -> [FocusEvent] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([FocusEvent].self, from: data) else { return [] }
        return events
    }

    private static func save(_ events: [FocusEvent], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: key) }
    }
}
