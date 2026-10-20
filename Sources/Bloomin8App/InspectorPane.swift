import Bloomin8Core
import AppKit
import SwiftUI

/// Detail for the selected grid item: a large preview plus the metadata the
/// widget could only fit into a tooltip, and the actions for that one image.
struct InspectorPane: View {
    let item: LibraryItem
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var preview: NSImage?
    @State private var info: [(String, String)] = []
    @State private var isSending = false
    @State private var showCrop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                previewImage

                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !info.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(info, id: \.0) { label, value in
                            HStack(alignment: .top) {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .leading)
                                Text(value)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Divider()
                actions
                MuseumCardPreview(item: item)
            }
            .padding(14)
        }
        .task(id: item.id) { await loadDetail() }
        .sheet(isPresented: $showCrop) {
            if let url = item.url {
                CropSheet(
                    imageURL: url,
                    canvasAspect: Double(settings.renderWidth) / Double(settings.renderHeight),
                    settings: settings
                ) { region in
                    Task { await controller.sendCropped(fileURL: url, crop: region) }
                }
            }
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
            if let preview {
                PrivacyImage(preview, settings: settings, gallery: item.galleryName, isLocalFile: item.url != nil)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .privacyBlur(settings: settings, gallery: item.galleryName, isLocalFile: item.url != nil)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 210)
        .overlay(alignment: .topTrailing) {
            PrivacyBlurButton(settings: settings, gallery: item.galleryName, isLocalFile: item.url != nil)
                .padding(8)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                send()
            } label: {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Send to Frame", systemImage: "paperplane")
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(isSending || controller.isBusy)

            if item.url != nil, !item.isVideo {
                Button {
                    showCrop = true
                } label: {
                    Label("Crop & Send…", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isSending || controller.isBusy)
            }

            if let url = item.url {
                if settings.favoriteImagePaths.contains(url.path) {
                    Button(role: .destructive) {
                        settings.favoriteImagePaths.removeAll { $0 == url.path }
                    } label: {
                        Label("Remove from Favorites", systemImage: "star.slash")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        settings.favoriteImagePaths.append(url.path)
                    } label: {
                        Label("Add to Favorites", systemImage: "star")
                            .frame(maxWidth: .infinity)
                    }
                }

                Button {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            if let url = item.url {
                controller.prepareBrowsedImage(url: url)
                while controller.localFolderCandidates.isEmpty && controller.isBusy {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let candidate = controller.localFolderCandidates.first {
                    await controller.confirmLocalFolderCandidate(candidate)
                    controller.cancelLocalFolderCandidate()
                }
            } else if let devicePath = item.devicePath {
                await controller.showImageAtPath(devicePath)
            } else if let assetID = item.photoAssetID {
                guard let data = await PhotosLibrarySource.fetchOriginalData(assetID: assetID) else { return }
                controller.preparePhotosLibraryImage(data: data, displayName: item.name, assetID: assetID)
                if let candidate = controller.localFolderCandidates.first {
                    await controller.confirmLocalFolderCandidate(candidate)
                    controller.cancelLocalFolderCandidate()
                }
            }
        }
    }

    private func loadDetail() async {
        preview = nil
        info = []

        if let url = item.url {
            preview = await ThumbnailStore.shared.thumbnail(for: url, maxPixelSize: 900)
            info = await Task.detached(priority: .utility) { localInfo(for: url) }.value
        } else if let devicePath = item.devicePath {
            info = [("Path", devicePath)]
            if let data = try? await BloominClient().fetchImageData(ip: settings.deviceIP, path: devicePath) {
                preview = NSImage(data: data)
                info.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))
            }
        } else if let assetID = item.photoAssetID {
            preview = await PhotosThumbnailStore.shared.thumbnail(assetID: assetID, maxPixelSize: 900)
            info = [("Taken", item.name)]
        }
    }
}

/// Off-main-thread: stats and decodes headers for the file.
private func localInfo(for url: URL) -> [(String, String)] {
    var rows: [(String, String)] = []
    rows.append(("Format", url.pathExtension.uppercased()))

    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attrs?[.size] as? Int64 {
        rows.append(("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
    }
    if let modified = attrs?[.modificationDate] as? Date {
        rows.append(("Modified", modified.formatted(date: .abbreviated, time: .shortened)))
    }
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let width = props[kCGImagePropertyPixelWidth] as? Int,
       let height = props[kCGImagePropertyPixelHeight] as? Int {
        rows.append(("Dimensions", "\(width) × \(height)"))
    }
    rows.append(("Path", url.deletingLastPathComponent().path))
    return rows
}
