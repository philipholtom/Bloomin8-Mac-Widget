import Bloomin8Core
import AppKit
import SwiftUI

/// Pushes a photo to the frame over the internet via the einkshot relay API
/// — for when the Mac isn't on the same network as the frame, unlike every
/// other send path in this app. Deliberately a separate flow from "Send to
/// Frame" rather than folded into it: different transport, different auth,
/// and delivery on the frame's next scheduled wake rather than immediately,
/// which would be confusing to mix into the LAN-send button.
struct SendRemotelyView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    @Environment(\.dismiss) private var dismiss

    private let client = EinkshotClient()

    @State private var status: EinkshotDeviceStatus?
    @State private var isLoadingStatus = false
    @State private var statusError: String?

    @State private var previewImage: NSImage?
    @State private var preparedJPEG: Data?

    @State private var isSending = false
    @State private var sendResult: String?
    @State private var sendError: String?
    @State private var isCancelling = false
    @State private var showPhotosPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send Remotely")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusRow

                    if settings.einkshotToken != nil {
                        pickerRow
                        sendButton
                        if let sendResult {
                            Text(sendResult)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let sendError {
                            Text(sendError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Divider()
                        pendingRow
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await loadStatus() }
        .sheet(isPresented: $showPhotosPicker) {
            RemotePhotosPickerSheet { assetID in
                Task { await pickFromPhotos(assetID: assetID) }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if settings.einkshotToken == nil {
                    Text("No token set")
                        .font(.subheadline.weight(.medium))
                    Text("Add one in Settings to use remote push.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isLoadingStatus {
                    Text("Checking…").font(.subheadline.weight(.medium))
                } else if let statusError {
                    Text("Couldn't reach remote service")
                        .font(.subheadline.weight(.medium))
                    Text(statusError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let status {
                    Text(status.name).font(.subheadline.weight(.medium))
                    Text(status.remoteImageOn
                        ? "Remote push on · interval \(status.remoteImageInterval)"
                        : "Remote push is disabled for this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let status, !isLoadingStatus {
                Text(status.remoteImageOn ? "Ready" : "Off")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(status.remoteImageOn ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                    .foregroundStyle(status.remoteImageOn ? .green : .secondary)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Picker

    private var pickerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.12))
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 90, height: 120)

            VStack(spacing: 8) {
                Button {
                    pickFromLocalFolder()
                } label: {
                    Label("Choose from Local Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    showPhotosPicker = true
                } label: {
                    Label("Choose from Apple Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var sendButton: some View {
        Button {
            push()
        } label: {
            if isSending {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                Label("Push to Frame", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSending || preparedJPEG == nil)
    }

    @ViewBuilder
    private var pendingRow: some View {
        HStack {
            if let status, status.hasPending {
                Text("An image is pending for the next wake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No image pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                cancelPending()
            } label: {
                if isCancelling {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Cancel Pending")
                }
            }
            .disabled(isCancelling || status?.hasPending != true)
        }
    }

    // MARK: - Actions

    private func loadStatus() async {
        guard let token = settings.einkshotToken, !token.isEmpty else { return }
        isLoadingStatus = true
        statusError = nil
        do {
            status = try await client.fetchStatus(token: token)
        } catch {
            statusError = error.localizedDescription
        }
        isLoadingStatus = false
    }

    private func pickFromLocalFolder() {
        guard let url = FilePicker.chooseImages().first else { return }
        Task {
            controller.prepareBrowsedImage(url: url)
            while controller.localFolderCandidates.isEmpty && controller.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let candidate = controller.localFolderCandidates.first {
                previewImage = candidate.image
                preparedJPEG = candidate.jpegData
            }
            controller.cancelLocalFolderCandidate()
        }
    }

    private func pickFromPhotos(assetID: String) async {
        guard let data = await PhotosLibrarySource.fetchOriginalData(assetID: assetID) else { return }
        controller.preparePhotosLibraryImage(data: data, displayName: "Remote")
        if let candidate = controller.localFolderCandidates.first {
            previewImage = candidate.image
            preparedJPEG = candidate.jpegData
        }
        controller.cancelLocalFolderCandidate()
    }

    private func push() {
        guard let jpeg = preparedJPEG, let token = settings.einkshotToken else { return }
        isSending = true
        sendError = nil
        sendResult = nil
        Task {
            defer { isSending = false }
            do {
                let result = try await client.pushImage(token: token, imageData: jpeg)
                sendResult = "Queued — displays at the frame's next wake (\(formattedTime(result.estimatedPushTime)))."
                await loadStatus()
            } catch {
                sendError = error.localizedDescription
            }
        }
    }

    private func cancelPending() {
        guard let token = settings.einkshotToken else { return }
        isCancelling = true
        Task {
            defer { isCancelling = false }
            _ = try? await client.cancelPending(token: token)
            await loadStatus()
        }
    }

    private func formattedTime(_ iso8601: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// A compact grid picker for choosing one Apple Photos image, presented as
/// its own nested sheet rather than reusing the app's main Apple Photos
/// grid — this flow only ever needs one photo, not the full browsing UI.
struct RemotePhotosPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [String] = []
    @State private var isLoading = true
    @State private var accessDenied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose from Apple Photos")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if accessDenied {
                Text("Photos access denied. Enable it for Bloomin8 Mac in System Settings → Privacy & Security → Photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(assets, id: \.self) { assetID in
                            RemotePhotoCell(assetID: assetID) {
                                onPick(assetID)
                                dismiss()
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 520, height: 480)
        .task {
            guard await PhotosLibrarySource.requestAccess() else {
                accessDenied = true
                isLoading = false
                return
            }
            let fetched = await Task.detached(priority: .userInitiated) {
                PhotosLibrarySource.fetchAllImageAssets()
            }.value
            assets = fetched.map(\.localIdentifier)
            isLoading = false
        }
    }
}

private struct RemotePhotoCell: View {
    let assetID: String
    let action: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.15))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 100)
            .clipped()
        }
        .buttonStyle(.plain)
        .task {
            image = await PhotosThumbnailStore.shared.thumbnail(assetID: assetID, maxPixelSize: 300)
        }
    }
}
