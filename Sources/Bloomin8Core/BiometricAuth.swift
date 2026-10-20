import LocalAuthentication

/// Touch ID as a faster path to unlocking a gallery tab or Local Folder/
/// Favorites — never a replacement for the app's own password, which stays
/// the actual secret and the required fallback whenever biometrics aren't
/// available or a scan fails.
///
/// Deliberately uses `.deviceOwnerAuthenticationWithBiometrics`, not
/// `.deviceOwnerAuthentication`: the latter lets the system dialog itself
/// fall back to the Mac's *login* password, which has nothing to do with
/// the tab/folder password this app manages — that would mean two different
/// secrets both "count" as unlocking the same thing. Biometrics-only means
/// any failure (no hardware, not enrolled, cancelled, a bad scan) simply
/// falls through to this app's own password field instead.
public enum BiometricAuth {
    public static func isAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Prompts Touch ID with `reason` shown in the system dialog. Returns
    /// true only on a genuine biometric success.
    @MainActor
    public static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                Task { @MainActor in
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
