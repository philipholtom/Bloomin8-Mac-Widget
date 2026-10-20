import Bloomin8Core
import AppKit
import SwiftUI

/// Shows 3 random photos from the selected galleries to pick from, with
/// Next for 3 more, before anything is actually (re)displayed — the same
/// "look at a few before committing" pattern already used for Local Folder
/// and generated content. The "Random Photo" button on the main Frame pane
/// used to send the first pick immediately with no picker step.
struct RandomPhotoPickerSheet: View {
    @ObservedObject var controller: PhotoController
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case picking
        case confirming
    }

    @State private var stage: Stage = .picking
    @State private var isFetching = true
    @State private var isRefreshing = false
    @State private var isSending = false
    @State private var selected: PhotoController.RandomPhotoCandidate?
    @State private var fetchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Random Photo")
                    .font(.headline)
                Spacer()
                PrivacyBlurButton(
                    settings: controller.settings,
                    gallery: controller.randomPhotoCandidates.map(\.gallery).first { PrivacyBlur.appliesTo(settings: controller.settings, gallery: $0, isLocalFile: false) }
                )
                if stage == .picking, !isFetching, !controller.randomPhotoCandidates.isEmpty {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Next", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
                Button("Cancel") { dismiss() }
                    .disabled(isSending)
            }

            content
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .task { await refresh() }
        .onDisappear {
            // Only relevant if dismissed mid-confirm without sending — a
            // completed send already clears this itself.
            controller.cancelRandomPhotoCandidates()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .picking: pickingContent
        case .confirming: confirmingContent
        }
    }

    @ViewBuilder
    private var pickingContent: some View {
        if isFetching {
            VStack(spacing: 10) {
                ProgressView()
                Text("Picking random photos…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fetchError, controller.randomPhotoCandidates.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(fetchError)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Pick one to send, or Next for 3 more")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(controller.randomPhotoCandidates) { candidate in
                    // Plain .onTapGesture, not Button — the same fix already
                    // established for this project's other candidate grids
                    // (see ContentSourcePickerSheet/LocalFolderCandidatePickerSheet),
                    // where Button showed intermittent missed clicks.
                    PrivacyImage(candidate.image, settings: controller.settings, gallery: candidate.gallery)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .privacyBlur(settings: controller.settings, gallery: candidate.gallery)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selected = candidate
                            stage = .confirming
                        }
                }
            }
            .opacity(isRefreshing ? 0.5 : 1)
            .allowsHitTesting(!isRefreshing)
            .overlay {
                if isRefreshing {
                    ProgressView("Getting new options…")
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var confirmingContent: some View {
        VStack(spacing: 14) {
            if let selected {
                PrivacyImage(selected.image, settings: controller.settings, gallery: selected.gallery)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .privacyBlur(settings: controller.settings, gallery: selected.gallery)
            }

            if !controller.statusText.isEmpty {
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back to Options") {
                    stage = .picking
                }
                .disabled(isSending)

                Spacer()

                Button {
                    confirmSend()
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send to Frame")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || selected == nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() async {
        // First load shows the full-screen spinner; a "Next" re-fetch keeps
        // the current set dimmed underneath instead, so it doesn't flash to
        // empty while new ones come in.
        isFetching = controller.randomPhotoCandidates.isEmpty
        isRefreshing = !isFetching
        fetchError = nil
        await controller.prepareRandomPhotoCandidates()
        if controller.randomPhotoCandidates.isEmpty {
            fetchError = controller.statusText.isEmpty
                ? "Couldn't find any random photos."
                : controller.statusText
        }
        isFetching = false
        isRefreshing = false
    }

    private func confirmSend() {
        guard let selected else { return }
        isSending = true
        Task {
            await controller.showImageAtPath(selected.devicePath)
            isSending = false
            if controller.statusText.contains("✓") {
                controller.cancelRandomPhotoCandidates()
                dismiss()
            }
            // On failure the status line above already explains why — leave
            // the sheet open on the same option so Send can be retried.
        }
    }
}
