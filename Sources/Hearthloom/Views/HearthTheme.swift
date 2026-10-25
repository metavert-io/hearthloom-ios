import SwiftUI

/// Minimal shared palette so the native chrome reads as one app around the
/// webview. Kept intentionally small — the dashboard SPA owns most styling.
enum HearthTheme {
    static let accent = Color(red: 0.86, green: 0.53, blue: 0.24)   // ember
    static let background = Color(.systemBackground)
    static let secondary = Color(.secondarySystemBackground)
}
