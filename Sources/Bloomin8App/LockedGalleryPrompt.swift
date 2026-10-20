import Bloomin8Core
import SwiftUI

/// Shown as the detail pane when the selected gallery belongs to a tab
/// that's locked and hasn't been unlocked this session — mirrors the
/// widget's `lockedTabPrompt`. Unlock state (`PhotoController.unlockedTabIDs`)
/// lives on the controller instance, which is per-process, so unlocking here
/// doesn't carry over to the widget or vice versa.
struct LockedGalleryPrompt: View {
    let tab: GalleryTab
    @ObservedObject var controller: PhotoController
    @ObservedObject var settings: AppSettings

    @State private var passwordDraft = ""
    @State private var showError = false
    @State private var isCheckingBiometrics = false

    private var offerTouchID: Bool {
        settings.useTouchIDForLocks && BiometricAuth.isAvailable()
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("'\(tab.name)' is locked")
                .font(.headline)

            if offerTouchID {
                Button {
                    Task { await attemptTouchIDUnlock() }
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingBiometrics)

                Text("or enter the password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("Password", text: $passwordDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(attemptUnlock)

            if showError {
                Text("Incorrect password.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Unlock") { attemptUnlock() }
                .buttonStyle(.borderedProminent)
                .disabled(passwordDraft.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tab.id) { _ in
            passwordDraft = ""
            showError = false
        }
        .task(id: tab.id) {
            if offerTouchID {
                await attemptTouchIDUnlock()
            }
        }
    }

    private func attemptUnlock() {
        if controller.unlock(tab: tab, password: passwordDraft) {
            showError = false
            passwordDraft = ""
        } else {
            showError = true
        }
    }

    private func attemptTouchIDUnlock() async {
        isCheckingBiometrics = true
        let success = await BiometricAuth.authenticate(reason: "unlock '\(tab.name)'")
        isCheckingBiometrics = false
        if success {
            controller.unlockedTabIDs.insert(tab.id)
        }
    }
}
