import Bloomin8Core
import AppKit
import SwiftUI

/// A Finder-style browser over any folder on this Mac — unlike the Local
/// Folder tab's flat, fully-recursive list of one fixed path, this shows one
/// folder level at a time, lets you navigate into subfolders, and lets you
/// change which folder it's rooted at ("Change Folder…") without touching
/// the Local Folder setting. "Random from Here" picks (recursively) from
/// wherever you've navigated to. Shares the Local Folder/Favorites lock —
/// it's the same "my private local files" concern, just a different way to
/// get at them.
struct FileBrowserView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    fileprivate struct Entry: Identifiable, Hashable {
        enum Kind { case folder, image, video }
        let url: URL
        let kind: Kind
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    @State private var currentPath: URL?
    @State private var entries: [Entry] = []
    @State private var isLoading = false
    @State private var selectedID: String?
    @State private var videoEntry: Entry?
    @State private var cropEntry: Entry?
    @State private var showRandomPicker = false
    @State private var showAddToGallery = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 14)]

    /// Browse Files isn't confined to the Local Folder path — it remembers
    /// its own root (`browseFilesRootPath`), independently changeable from
    /// right here with "Choose Folder…". Falls back to the Local Folder path
    /// only the first time, so there's somewhere sensible to start.
    private var rootPath: String {
        let own = settings.browseFilesRootPath.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? settings.randomFolderPath.trimmingCharacters(in: .whitespaces) : own
    }

    private var rootURL: URL? {
        rootPath.isEmpty ? nil : URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    var body: some View {
        Group {
            if rootURL == nil {
                chooseRootPrompt
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                message("This folder is empty.", symbol: "folder")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(entries) { entry in cell(for: entry) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) { breadcrumbBar }
        .onAppear {
            if currentPath == nil, let rootURL { navigate(to: rootURL) }
        }
        .sheet(isPresented: $showRandomPicker) {
            if let target = currentPath ?? rootURL {
                LocalFolderCandidatePickerSheet(controller: controller, source: .folder(target))
            }
        }
        .sheet(isPresented: $showAddToGallery) {
            if let target = currentPath ?? rootURL {
                AddRandomToGallerySheet(folder: target, controller: controller, settings: settings)
            }
        }
        .sheet(item: $videoEntry) { entry in
            VideoFramePickerSheet(videoURL: entry.url, controller: controller)
        }
        .sheet(item: $cropEntry) { entry in
            CropSheet(
                imageURL: entry.url,
                canvasAspect: Double(settings.renderWidth) / Double(settings.renderHeight),
                settings: settings
            ) { region in
                Task { await controller.sendCropped(fileURL: entry.url, crop: region) }
            }
        }
    }

    // MARK: - Breadcrumb

    /// Root first, then each path component down to `currentPath` — empty
    /// (beyond the root) until the first `navigate(to:)` completes.
    private var breadcrumbComponents: [URL] {
        guard let rootURL else { return [] }
        guard let currentPath else { return [rootURL] }
        let rootComps = rootURL.standardizedFileURL.pathComponents
        let curComps = currentPath.standardizedFileURL.pathComponents
        var urls = [rootURL]
        guard curComps.count > rootComps.count, Array(curComps.prefix(rootComps.count)) == rootComps else {
            return urls
        }
        var running = rootURL
        for component in curComps[rootComps.count...] {
            running = running.appendingPathComponent(component)
            urls.append(running)
        }
        return urls
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 10) {
            if let currentPath, let rootURL, currentPath.standardizedFileURL != rootURL.standardizedFileURL {
                Button {
                    navigate(to: currentPath.deletingLastPathComponent())
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Up one folder")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let crumbs = breadcrumbComponents
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, url in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(url.lastPathComponent) { navigate(to: url) }
                            .buttonStyle(.plain)
                            .font(.callout.weight(index == crumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.accentColor)
                    }
                }
            }

            Spacer()

            PrivacyBlurButton(settings: settings, isLocalFile: true)

            Button {
                chooseNewRoot()
            } label: {
                Label("Change Folder…", systemImage: "folder.badge.gearshape")
            }
            .help("Browse a different folder on this Mac")

            Button {
                showAddToGallery = true
            } label: {
                Label("Add to Gallery…", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(currentPath == nil || settings.deviceIP.isEmpty)
            .help("Upload random photos from this folder and its subfolders into a gallery on the frame")

            Button {
                showRandomPicker = true
            } label: {
                Label("Random from Here", systemImage: "shuffle")
            }
            .disabled(currentPath == nil)
            .help("Pick a random photo from this folder and its subfolders")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var chooseRootPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Choose a folder to browse.")
                .foregroundStyle(.secondary)
            Button("Choose Folder…") { chooseNewRoot() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Lets you point Browse Files at any folder on this Mac, independent of
    /// the Local Folder path — the whole reason this tab remembers its own
    /// root rather than reusing `randomFolderPath` directly.
    private func chooseNewRoot() {
        guard let folder = FilePicker.chooseFolder(title: "Choose a Folder to Browse") else { return }
        settings.browseFilesRootPath = folder.path
        navigate(to: folder)
    }

    // MARK: - Navigation

    /// Lists `url`'s immediate children — one level, not recursive, unlike
    /// the Local Folder tab's flat listing — off the main thread, since a
    /// folder on a slow network volume shouldn't freeze the window.
    private func navigate(to url: URL) {
        currentPath = url
        selectedID = nil
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var folders: [Entry] = []
            var files: [Entry] = []
            for item in contents {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    folders.append(Entry(url: item, kind: .folder))
                    continue
                }
                let ext = item.pathExtension.lowercased()
                if ImageFolder.imageFileExtensions.contains(ext) {
                    files.append(Entry(url: item, kind: .image))
                } else if VideoFolder.videoFileExtensions.contains(ext) {
                    files.append(Entry(url: item, kind: .video))
                }
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let result = folders + files

            await MainActor.run {
                self.entries = result
                self.isLoading = false
            }
        }
    }

    // MARK: - Cell

    private func cell(for entry: Entry) -> some View {
        FileBrowserCell(entry: entry, isSelected: selectedID == entry.id, settings: settings)
            .onTapGesture {
                switch entry.kind {
                case .folder:
                    navigate(to: entry.url)
                case .video:
                    videoEntry = entry
                case .image:
                    selectedID = entry.id
                }
            }
            .contextMenu { contextMenu(for: entry) }
    }

    @ViewBuilder
    private func contextMenu(for entry: Entry) -> some View {
        switch entry.kind {
        case .folder:
            Button("Open") { navigate(to: entry.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
            }
        case .video:
            Button("Pick a Frame to Send…") { videoEntry = entry }
            revealAndFavorite(for: entry, favoritable: false)
        case .image:
            Button("Send to Frame") { send(entry) }
            Button("Crop & Send…") { cropEntry = entry }
            revealAndFavorite(for: entry, favoritable: true)
        }
    }

    @ViewBuilder
    private func revealAndFavorite(for entry: Entry, favoritable: Bool) -> some View {
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }
        if favoritable {
            Divider()
            if settings.favoriteImagePaths.contains(entry.url.path) {
                Button("Remove from Favorites", role: .destructive) {
                    settings.favoriteImagePaths.removeAll { $0 == entry.url.path }
                }
            } else {
                Button("Add to Favorites") {
                    settings.favoriteImagePaths.append(entry.url.path)
                }
            }
        }
    }

    /// Same send pipeline `LibraryGrid` uses for a local file: render,
    /// dedupe-against-what's-already-on-the-frame, upload, display.
    private func send(_ entry: Entry) {
        Task {
            controller.prepareBrowsedImage(url: entry.url)
            while controller.localFolderCandidates.isEmpty && controller.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let candidate = controller.localFolderCandidates.first {
                await controller.confirmLocalFolderCandidate(candidate)
                controller.cancelLocalFolderCandidate()
            }
        }
    }
}

private struct FileBrowserCell: View {
    fileprivate typealias Entry = FileBrowserView.Entry
    let entry: Entry
    let isSelected: Bool
    let settings: AppSettings

    @State private var thumbnail: NSImage?
    @State private var didAttemptLoad = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.15))

                if entry.kind == .folder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                } else if let thumbnail {
                    PrivacyImage(thumbnail, settings: settings, isLocalFile: true)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .privacyBlur(settings: settings, isLocalFile: true)
                } else if didAttemptLoad {
                    Image(systemName: entry.kind == .video ? "film" : "questionmark.square.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }

                if entry.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
            }
            .frame(height: 110)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: isSelected ? 3 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: entry.id) {
            guard entry.kind != .folder else { return }
            thumbnail = await ThumbnailStore.shared.thumbnail(for: entry.url, maxPixelSize: 300)
            didAttemptLoad = true
        }
    }
}
