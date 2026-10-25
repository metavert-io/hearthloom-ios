import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Sentry APM bootstrap. The DSN comes from the `SENTRY_DSN` Info.plist key
/// (set in project.yml). An empty DSN disables Sentry entirely, so the app runs
/// fine before the DSN is filled in and in test targets. The DSN is a
/// client-side publishable key — it can only send events, never read them.
enum Observability {
    #if canImport(Sentry)
    /// The options Sentry started with. Its network tracker reads
    /// `tracePropagationTargets` from this same object on every request, so
    /// `setNode` updates it in place.
    private static var options: Options?
    #endif
    /// The connected node, if any — the only origin that gets trace headers.
    private static var node: URL?
    private static let lock = NSLock()

    static func start() {
        #if canImport(Sentry)
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String,
              !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.enableAppHangTracking = true      // catches the watchdog-style freezes
            options.attachViewHierarchy = false       // privacy: no UI capture
            options.sendDefaultPii = false
            // Distributed tracing: auto network tracking attaches sentry-trace /
            // baggage headers to outgoing requests, and the daemon continues them
            // into a server transaction (end-to-end phone→node trace). Those
            // headers go to the connected node ONLY — never to a hosted provider
            // or any other host. Usually no node is known yet at launch (it's
            // behind Face ID), so this starts empty and `setNode` fills it in.
            lock.withLock {
                options.tracePropagationTargets = propagationTargets(for: node)
                Observability.options = options
            }
            options.enableAutoPerformanceTracing = true
            options.enableNetworkTracking = true
            #if DEBUG
            options.environment = "debug"
            options.tracesSampleRate = 1.0
            #else
            options.environment = "production"
            options.tracesSampleRate = 0.2
            #endif
        }
        #endif
    }

    /// Point trace propagation at the connected node (nil = no node: no request
    /// carries trace headers). Called whenever the connection changes, and by
    /// the capture drain, which can run with no unlocked connection.
    static func setNode(_ baseURL: URL?) {
        lock.withLock {
            guard baseURL != node else { return }
            node = baseURL
            #if canImport(Sentry)
            options?.tracePropagationTargets = propagationTargets(for: baseURL)
            #endif
        }
    }

    /// The node's origin and nothing else: anchored, so a look-alike host such
    /// as `node.example.com.other.test` or a different port doesn't match.
    static func propagationTargets(for baseURL: URL?) -> [NSRegularExpression] {
        guard let baseURL, let scheme = baseURL.scheme?.lowercased(),
              var host = baseURL.host?.lowercased(), !host.isEmpty else { return [] }
        if host.contains(":") { host = "[\(host)]" }   // IPv6 literal
        let origin = "\(scheme)://\(host)" + (baseURL.port.map { ":\($0)" } ?? "")
        let pattern = "^" + NSRegularExpression.escapedPattern(for: origin) + "(?:[/?#]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        return [regex]
    }

    /// Manually record a non-fatal error with a context tag (adapter name, etc.).
    static func capture(_ error: Error, tags: [String: String] = [:]) {
        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            for (k, v) in tags { scope.setTag(value: v, key: k) }
        }
        #endif
    }

    /// Run an async operation inside a Sentry transaction so it appears as a
    /// phone-side span that continues into the daemon (the auto network span for
    /// the request inside becomes its child, carrying the trace headers). Compiles
    /// to a plain call when Sentry isn't built in.
    static func traced<T>(_ name: String, operation: String = "ingest",
                          _ body: () async throws -> T) async rethrows -> T {
        #if canImport(Sentry)
        let tx = SentrySDK.startTransaction(name: name, operation: operation, bindToScope: true)
        do {
            let result = try await body()
            tx.finish()
            return result
        } catch {
            tx.finish(status: .internalError)
            throw error
        }
        #else
        return try await body()
        #endif
    }
}
