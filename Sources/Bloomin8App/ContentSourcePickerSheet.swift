import Bloomin8Core
import AppKit
import SwiftUI

/// Shows 3 random renders from a generated content source to choose from,
/// then confirms before sending — same "look at a few, Next for more,
/// confirm before it actually sends" pattern as `VideoFramePickerSheet` and
/// the widget's Local Folder candidate picker. Parameterized by
/// `ContentSource` rather than one sheet per source (first built for NASA
/// APOD, then asked for again for Fortune) — both vary enough per call
/// that seeing options first is worth it, and the picker UI itself doesn't
/// need to know which source it's showing.
struct ContentSourcePickerSheet: View {
    let source: ContentSource
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
    @State private var selected: PhotoController.LocalFolderCandidate?
    @State private var fetchError: String?
    @State private var isFetchingToday = false
    @State private var todayError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(source.displayName)
                    .font(.headline)
                Spacer()
                if stage == .picking, let todaySource = source as? TodayContentSource {
                    Button {
                        Task { await showToday(todaySource) }
                    } label: {
                        if isFetchingToday {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(todaySource.todayButtonTitle, systemImage: "calendar")
                        }
                    }
                    .disabled(isFetching || isRefreshing || isFetchingToday)
                }
                if stage == .picking, !isFetching, !controller.localFolderCandidates.isEmpty {
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

            if let todayError, stage == .picking {
                Label(todayError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            content
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .task { await refresh() }
        .onDisappear {
            // Only relevant if dismissed mid-confirm without sending — a
            // completed send already clears this itself.
            controller.cancelLocalFolderCandidate()
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
                Text("Generating \(source.displayName) options…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fetchError, controller.localFolderCandidates.isEmpty {
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
                ForEach(Array(controller.localFolderCandidates.enumerated()), id: \.offset) { _, candidate in
                    // Plain .onTapGesture, not Button — a Button here showed
                    // the same intermittent missed-click behavior as the
                    // video frame picker grid on this OS, before that one
                    // was switched over; using the same fix from the start.
                    Image(nsImage: candidate.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                Image(nsImage: selected.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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

    /// Today's picture goes straight to the confirm step — it's one specific
    /// item, so there's nothing to choose between.
    private func showToday(_ todaySource: TodayContentSource) async {
        isFetchingToday = true
        todayError = nil
        let error = await controller.prepareTodayCandidate(source: todaySource)
        isFetchingToday = false
        if let error {
            todayError = error
        } else if let candidate = controller.localFolderCandidates.first {
            selected = candidate
            stage = .confirming
        }
    }

    private func refresh() async {
        // First load shows the full-screen spinner; a "Next" re-fetch keeps
        // the current set dimmed underneath instead, so it doesn't flash
        // to empty while new ones come in.
        isFetching = controller.localFolderCandidates.isEmpty
        isRefreshing = !isFetching
        fetchError = nil
        todayError = nil
        await controller.prepareContentCandidates(source: source)
        if controller.localFolderCandidates.isEmpty {
            fetchError = "Couldn't generate any \(source.displayName) options right now."
        }
        isFetching = false
        isRefreshing = false
    }

    private func confirmSend() {
        guard let selected else { return }
        isSending = true
        Task {
            await controller.confirmLocalFolderCandidate(selected)
            isSending = false
            if controller.statusText.contains("✓") {
                controller.cancelLocalFolderCandidate()
                dismiss()
            }
            // On failure the status line above already explains why — leave
            // the sheet open on the same option so Send can be retried.
        }
    }
}
