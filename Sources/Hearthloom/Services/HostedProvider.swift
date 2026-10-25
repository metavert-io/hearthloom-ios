import Foundation

/// A hosted provider: a service that runs Hearthloom nodes for its users and
/// has its own accounts. The Connect screen lists one under "Hosted providers"
/// below the self-hosting options, and never selects it for you.
///
/// Which provider is listed is a build setting, not code:
/// `HEARTHLOOM_PROVIDER_NAME` / `HEARTHLOOM_PROVIDER_URL` in
/// `Config/Signing.xcconfig` (override them in `Config/Signing.local.xcconfig`)
/// flow into Info.plist. An empty URL hides the option.
struct HostedProvider: Equatable {
    let name: String
    let url: URL

    static let nameKey = "HearthloomProviderName"
    static let urlKey = "HearthloomProviderURL"

    /// The provider to list on the Connect screen, or nil to list none.
    static var listed: HostedProvider? {
        let process = ProcessInfo.processInfo
        // UI tests pin the listing (or hide it with an empty URL) so they don't
        // depend on whoever built the app.
        if process.arguments.contains("--uitest-reset"),
           let url = process.environment["HLIOS_UITEST_PROVIDER_URL"] {
            return configured(name: process.environment["HLIOS_UITEST_PROVIDER_NAME"], url: url)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        return configured(name: info[nameKey] as? String, url: info[urlKey] as? String)
    }

    /// Pure: build-setting values → a provider. A blank or invalid URL means
    /// "list none"; a blank name falls back to the URL's host.
    static func configured(name: String?, url: String?) -> HostedProvider? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let base = HearthAPI.normalize(raw) else { return nil }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HostedProvider(name: label.isEmpty ? (base.host ?? base.absoluteString) : label,
                              url: base)
    }
}
