import Bloomin8Core
import AppKit
import SwiftUI

/// The "easy" alternative to a full scrubbing player: pulls a handful of
/// frames spread across the video and lets the user click one, then confirm
/// it before it actually sends — rather than building timeline/seek UI
/// around video playback, or sending the instant you tap a thumbnail. "Next"
/// re-draws a fresh set (VideoFrameExtractor jitters within each time slot,
/// so it's not the same 9 frames again) for anyone who wants to see more
/// options without needing to scrub to a specific moment.
struct VideoFramePickerSheet: View {
    let videoURL: URL
    @ObservedObject var controller: PhotoController
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case picking
        /// A frame's been tapped and rendered into a candidate
        /// (`controller.localFolderCandidates.first`) — shown big, with a
        /// chance to back out, before anything is actually sent.
        case confirming
    }

    @State private var frames: [NSImage] = []
    @State private var isExtracting = true
    @State private var isRefreshing = false
    @State private var isSending = false
    @State private var stage: Stage = .picking

    private var isBusy: Bool { isRefreshing || isSending }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(videoURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if stage == .picking, !isExtracting, !frames.isEmpty {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Next", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                }
                Button("Cancel") { dismiss() }
                    .disabled(isSending)
            }

            content
        }
        .padding(20)
        .frame(width: 640, height: 540)
        .task {
            frames = await VideoFrameExtractor.extractFrames(from: videoURL, count: 9)
            isExtracting = false
        }
        .onDisappear {
            // Only relevant if the sheet is dismissed mid-confirm (e.g. via
            // Cancel) without ever sending — a completed send already clears
            // this itself.
            controller.cancelLocalFolderCandidate()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .picking:
            pickingContent
        case .confirming:
            confirmingContent
        }
    }

    @ViewBuilder
    private var pickingContent: some View {
        if isExtracting {
            VStack(spacing: 10) {
                ProgressView()
                Text("Pulling frames from the video…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if frames.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Couldn't read any frames from this file.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Pick a frame to send, or try Next for a different set")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                        // Plain .onTapGesture, not Button: diagnostic logging
                        // showed the *same* click coordinates, in the *same*
                        // cell, sometimes fired the Button's action and
                        // sometimes didn't — genuinely intermittent, not a
                        // geometry mismatch, meaning Button's own gesture
                        // recognition is what's unreliable here (inside a
                        // LazyVGrid, on this OS). Same fix as the sidebar
                        // bug earlier: the simpler, more direct gesture
                        // works where the higher-level control didn't.
                        PrivacyImage(frame, settings: controller.settings, isLocalFile: true)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 110)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .privacyBlur(settings: controller.settings, isLocalFile: true)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectFrame(frame)
                            }
                    }
                }
            }
            .disabled(isBusy)
            .opacity(isRefreshing ? 0.5 : 1)
            .overlay {
                if isRefreshing {
                    ProgressView("Getting new frames…")
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// Preview of the frame that's about to be sent, plus the same live
    /// request/response log (`controller.statusText`, e.g. "→ POST
    /// /upload…" / "← /upload OK") shown for every other photo send — the
    /// sheet is modal and covers the sidebar footer where that normally
    /// appears, so it's surfaced here too rather than being invisible while
    /// this is open.
    @ViewBuilder
    private var confirmingContent: some View {
        let candidate = controller.localFolderCandidates.first

        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.15))
                if let image = candidate?.image {
                    PrivacyImage(image, settings: controller.settings, isLocalFile: true)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .privacyBlur(settings: controller.settings, isLocalFile: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let candidate {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(candidate.jpegData.count), countStyle: .file)) JPEG")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !controller.statusText.isEmpty {
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back to Frames") {
                    controller.cancelLocalFolderCandidate()
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
                .disabled(isSending || candidate == nil)
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        let next = await VideoFrameExtractor.extractFrames(from: videoURL, count: 9)
        // A genuine extraction failure (e.g. the file became unreadable) is
        // rare and momentary — keep showing the last good set rather than
        // replacing it with the empty-state message.
        if !next.isEmpty { frames = next }
        isRefreshing = false
    }

    private func selectFrame(_ frame: NSImage) {
        guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        controller.prepareVideoFrame(cgImage: cgImage, sourceURL: videoURL)
        stage = .confirming
    }

    private func confirmSend() {
        guard let candidate = controller.localFolderCandidates.first else { return }
        isSending = true
        Task {
            await controller.confirmLocalFolderCandidate(candidate)
            isSending = false
            if controller.statusText.contains("✓") {
                controller.cancelLocalFolderCandidate()
                dismiss()
            }
            // On failure the status line above already explains why —
            // leave the sheet open on the same frame so Send can be
            // retried without re-picking, or Back to Frames tried instead.
        }
    }
}
