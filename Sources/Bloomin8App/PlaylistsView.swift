import Bloomin8Core
import SwiftUI

/// The frame's own playlists: an ordered list of photos, each shown for a
/// number of seconds. The frame plays them itself, so they keep running
/// with this Mac off or asleep. (Only "duration" playlists — the frame's
/// time-of-day type isn't documented well enough to build on yet.)
struct PlaylistsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var playlists: [BloominClient.PlaylistSummary] = []
    @State private var selected: String?
    @State private var items: [BloominClient.PlaylistItem] = []
    @State private var loadError: String?
    @State private var loading = false
    @State private var dirty = false

    @State private var showNew = false
    @State private var newName = ""
    @State private var addGallery = ""
    @State private var addMode: AddMode = .all
    @State private var addCount = 10
    @State private var addSeconds = 300
    @State private var pendingDelete: String?
    @State private var message: String?

    private enum AddMode: String, CaseIterable, Identifiable {
        case all = "All photos"
        case random = "Random photos"
        var id: String { rawValue }
    }

    /// Galleries that aren't behind a still-locked tab.
    private var openGalleries: [String] {
        controller.galleries.filter { settings.lockedTab(for: $0, unlockedTabIDs: controller.unlockedTabIDs) == nil }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            detail.frame(minWidth: 420)
        }
        .task { await reload() }
        .sheet(isPresented: $showNew) { newSheet }
        .alert("Delete playlist '\(pendingDelete ?? "")'?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                guard let name = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    if await controller.deletePlaylist(name) {
                        if selected == name { selected = nil; items = [] }
                        await reload()
                    }
                }
            }
        } message: {
            Text("This removes the playlist from the frame. The photos stay.")
        }
    }

    // MARK: - Left: the playlists

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playlists").font(.headline)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Reload from the frame")
                Button { newName = ""; showNew = true } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).help("New playlist")
            }
            .padding(12)
            Divider()
            if loading && playlists.isEmpty {
                ProgressView().padding()
                Spacer()
            } else if let loadError, playlists.isEmpty {
                Text(loadError).font(.caption).foregroundStyle(.secondary).padding()
                Spacer()
            } else if playlists.isEmpty {
                Text("No playlists on the frame yet. Press + to make one.")
                    .font(.caption).foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(playlists) { playlist in
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                if isPlaying(playlist.name) {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                }
                            }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected == playlist.name ? Color.accentColor.opacity(0.18) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await select(playlist.name) } }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Right: one playlist

    @ViewBuilder
    private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selected).font(.title2.bold())
                    Spacer()
                    if isPlaying(selected) {
                        Button("Stop") { Task { await controller.stopSlideshow() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(controller.isBusy)
                            .help("Stop this playlist; the frame keeps the photo it's showing")
                    } else {
                        Button("Play on frame") { Task { await controller.playPlaylist(selected) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(items.isEmpty || dirty || controller.isBusy)
                            .help(dirty ? "Save your changes first" : "Start this playlist on the frame")
                    }
                    Button("Save") {
                        Task {
                            if await controller.savePlaylist(name: selected, items: items) {
                                dirty = false
                                message = "Saved to the frame."
                                await reload(keepSelection: true)
                            }
                        }
                    }
                    .disabled(!dirty || controller.isBusy)
                    Button("Delete…", role: .destructive) { pendingDelete = selected }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if isPlaying(selected) {
                    Label("Playing on the frame now", systemImage: "play.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Text("\(items.count) photos · about \(totalMinutes) min per cycle")
                    .font(.caption).foregroundStyle(.secondary)
                addControls
                Divider()
                if items.isEmpty {
                    Text("Empty — add photos from a gallery above.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                itemRow(index, item)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
        } else {
            VStack {
                Spacer()
                Text("Select a playlist, or make a new one.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Whether the frame says it's playing `name` right now.
    private func isPlaying(_ name: String) -> Bool {
        controller.deviceInfo?.playType == 2 && controller.deviceInfo?.playlist == name
    }

    private var totalMinutes: Int { max(1, items.reduce(0) { $0 + $1.durationSeconds } / 60) }

    private var addControls: some View {
        HStack {
            Picker("Add from", selection: $addGallery) {
                ForEach(openGalleries, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 220)
            Picker("", selection: $addMode) {
                ForEach(AddMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 140)
            if addMode == .random {
                Stepper("\(addCount)", value: $addCount, in: 1...100).fixedSize()
            }
            Stepper("\(addSeconds / 60) min each", value: $addSeconds, in: 60...86_400, step: 60).fixedSize()
            Button("Add") { Task { await addPhotos() } }
                .disabled(addGallery.isEmpty || controller.isBusy)
        }
        .onAppear { if addGallery.isEmpty { addGallery = openGalleries.first ?? "" } }
    }

    private func itemRow(_ index: Int, _ item: BloominClient.PlaylistItem) -> some View {
        let parts = item.path.split(separator: "/")
        let gallery = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
        let file = parts.last.map(String.init) ?? item.path
        let hidden = settings.lockedTab(for: gallery, unlockedTabIDs: controller.unlockedTabIDs) != nil
        return HStack {
            Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
            PlaylistThumbnail(settings: settings, path: item.path, gallery: gallery, hidden: hidden)
            VStack(alignment: .leading, spacing: 1) {
                Text(hidden ? "Hidden photo" : file).lineLimit(1)
                Text(hidden ? "Locked gallery" : gallery).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper("\(item.durationSeconds / 60) min", value: Binding(
                get: { items[index].durationSeconds },
                set: { items[index].durationSeconds = $0; dirty = true }
            ), in: 60...86_400, step: 60).fixedSize()
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.plain).disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.plain).disabled(index == items.count - 1)
            Button { items.remove(at: index); dirty = true } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    // MARK: - New playlist

    private var newSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Playlist").font(.headline)
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 260)
            Text("Use letters, numbers, dashes or underscores.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showNew = false }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " ", with: "_")
                    guard !name.isEmpty else { return }
                    showNew = false
                    if !playlists.contains(where: { $0.name == name }) {
                        playlists.append(.init(name: name, time: nil))
                    }
                    selected = name
                    items = []
                    dirty = true
                    message = "Not on the frame until you press Save."
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Actions

    private func reload(keepSelection: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await controller.loadPlaylists()
            // Keep a freshly created, unsaved playlist visible.
            var merged = loaded
            if let selected, !loaded.contains(where: { $0.name == selected }), dirty {
                merged.append(.init(name: selected, time: nil))
            }
            playlists = merged
            loadError = nil
            if keepSelection, let selected, loaded.contains(where: { $0.name == selected }) { await select(selected) }
        } catch {
            loadError = "Couldn't read playlists: \(error.localizedDescription)"
        }
    }

    private func select(_ name: String) async {
        selected = name
        message = nil
        dirty = false
        do {
            items = try await controller.loadPlaylist(name).items
        } catch {
            items = []
            message = "Couldn't read this playlist: \(error.localizedDescription)"
        }
    }

    private func addPhotos() async {
        do {
            var paths = try await controller.galleryImagePaths(addGallery)
            if addMode == .random { paths = Array(paths.shuffled().prefix(addCount)) }
            items.append(contentsOf: paths.map { BloominClient.PlaylistItem(path: $0, durationSeconds: addSeconds) })
            dirty = true
            message = "Added \(paths.count) photos — press Save to put them on the frame."
        } catch {
            message = "Couldn't read gallery '\(addGallery)': \(error.localizedDescription)"
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        dirty = true
    }
}

/// A small preview of a playlist photo, loaded from the frame and cached.
/// Click it for a larger look. A photo in a still-locked gallery shows a
/// lock instead of its picture.
private struct PlaylistThumbnail: View {
    @ObservedObject var settings: AppSettings
    let path: String
    let gallery: String
    let hidden: Bool

    private var landscape: Bool { settings.renderWidth > settings.renderHeight }

    @State private var image: NSImage?
    @State private var large: NSImage?
    @State private var showLarge = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15))
            if hidden {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            } else if let image {
                PrivacyImage(image, settings: settings, gallery: gallery)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .privacyBlur(settings: settings, gallery: gallery)
            }
        }
        .frame(width: landscape ? 64 : 48, height: landscape ? 48 : 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !hidden, image != nil else { return }
            showLarge = true
            Task {
                if large == nil {
                    large = await DeviceThumbnailStore.shared.cachedThumbnail(ip: settings.deviceIP, path: path, sizes: [700])
                    if large == nil {
                        large = await DeviceThumbnailStore.shared.thumbnail(ip: settings.deviceIP, path: path, maxPixelSize: 700)
                    }
                }
            }
        }
        .popover(isPresented: $showLarge) {
            Group {
                if let shown = large ?? image {
                    PrivacyImage(shown, settings: settings, gallery: gallery)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .privacyBlur(settings: settings, gallery: gallery)
                } else {
                    ProgressView()
                }
            }
            .frame(width: landscape ? 440 : 330, height: landscape ? 330 : 440)
            .padding(8)
        }
        .task(id: path) {
            guard !hidden, image == nil else { return }
            // Reuse whatever the gallery grid, pickers or museum cards already
            // fetched (any size, no frame needed); only ask the frame if none.
            let store = DeviceThumbnailStore.shared
            image = await store.cachedThumbnail(ip: settings.deviceIP, path: path, sizes: [320, 300, 700, 160])
            if image == nil {
                image = await store.thumbnail(ip: settings.deviceIP, path: path, maxPixelSize: 320)
            }
        }
    }
}
