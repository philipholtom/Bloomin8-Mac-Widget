import Bloomin8Core
import SwiftUI

/// Shown as the detail pane for Local Folder or Favorites when the shared
/// local-photos password is set and hasn't been entered this session —
/// mirrors LockedGalleryPrompt. One password/unlock covers both sources
/// (see PhotoController.isLocalFolderUnlocked); which one you unlocked from
/// doesn't matter.
struct LockedLocalFolderPrompt: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

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
            Text("Your photos are locked")
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
        .task {
            if offerTouchID {
                await attemptTouchIDUnlock()
            }
        }
    }

    private func attemptUnlock() {
        guard let hash = settings.localFolderPasswordHash else {
            showError = true
            return
        }
        let result = PasswordHasher.verify(passwordDraft, against: hash)
        guard result.matched else {
            showError = true
            return
        }
        if let upgraded = result.upgradedHash {
            settings.localFolderPasswordHash = upgraded
        }
        showError = false
        passwordDraft = ""
        controller.isLocalFolderUnlocked = true
    }

    private func attemptTouchIDUnlock() async {
        isCheckingBiometrics = true
        let success = await BiometricAuth.authenticate(reason: "unlock Local Folder and Favorites")
        isCheckingBiometrics = false
        if success {
            controller.isLocalFolderUnlocked = true
        }
    }
}
