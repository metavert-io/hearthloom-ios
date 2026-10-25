import Foundation

/// Formatting helpers shared by the device-adapter status screens.
enum DeviceSync {
    /// "Never", or a relative string like "2 min ago" / an absolute date+time.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Absolute date + time, e.g. "Aug 10, 3:12 PM".
    static func stamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
