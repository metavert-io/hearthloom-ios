import Foundation
import LocalAuthentication

/// Face ID / Touch ID gate. Produces an *authenticated* `LAContext` that is then
/// handed to `KeychainStore` reads so app-open is a single biometric prompt.
///
/// Two distinct gates use this:
///  1. App open — unlock the Keychain device token.
///  2. Vault unlock — authorize sending `POST /v1/vault {action:"unlock"}`.
enum BiometricGate {
    enum GateError: LocalizedError {
        case unavailable(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let m): return m
            case .failed(let m): return m
            }
        }
    }

    /// Human-readable biometry name for button labels ("Face ID" / "Touch ID").
    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "biometrics"
        }
    }

    /// Evaluate biometrics (with passcode fallback) and return the authenticated
    /// context. `.deviceOwnerAuthentication` includes the passcode fallback so a
    /// failed/absent face still lets the owner in — matching the Keychain
    /// `.userPresence` policy used for reads.
    @discardableResult
    static func evaluate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            throw GateError.unavailable(
                authError?.localizedDescription ??
                "This device can't verify your identity. Set a passcode to use Hearthloom.")
        }

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return context
        } catch let laError as LAError {
            if laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                throw GateError.failed("Cancelled.")
            }
            throw GateError.failed(laError.localizedDescription)
        }
    }
}
