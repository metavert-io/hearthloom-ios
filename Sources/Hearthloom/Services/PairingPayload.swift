import Foundation

/// Parses the dashboard's pairing QR (Integrations → Pair a device). The card
/// encodes `hearthloom://pair?url=<origin>&pat=<secret>` (both percent-encoded)
/// — see hearthloom's `crates/hearthloom-daemon/assets/integrations.js`.
/// Pure + testable.
enum PairingPayload {
    /// Returns the node base URL and device PAT, or nil if the string isn't a
    /// valid Hearthloom pairing code.
    static func parse(_ raw: String) -> (url: URL, pat: String)? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "hearthloom",
              comps.host?.lowercased() == "pair" else { return nil }
        let items = comps.queryItems ?? []
        guard
            let urlStr = items.first(where: { $0.name == "url" })?.value,
            let pat = items.first(where: { $0.name == "pat" })?.value, !pat.isEmpty,
            let url = HearthAPI.normalize(urlStr)
        else { return nil }
        return (url, pat)
    }
}
