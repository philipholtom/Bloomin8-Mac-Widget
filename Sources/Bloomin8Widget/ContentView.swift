import Bloomin8Core
import SwiftUI
import AppKit

/// Decoded favorite thumbnails, keyed by file path. SwiftUI re-evaluates the
/// favorites grid on every state change, and decoding each full-size photo
/// from disk each time visibly stutters the popover once there are more than
/// a couple of favorites.
private let favoriteThumbnailCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 200
    return cache
}()

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var showSettings: Bool = false
    @State private var ipDraft: String = ""
    @State private var bleNameDraft: String = ""
    @State private var nasaApiKeyDraft: String = ""
    @State private var deviceNameDraft: String = ""
    @State private var maxIdleMinutesDraft: String = ""
    @State private var sleepDurationHoursDraft: String = ""
    @State private var wakeSensitivityDraft: String = ""

    @State private var slideshowGallery: String = ""
    @State private var slideshowDurationDraft: String = "5"

    @State private var manageGallery: String = ""
    @State private var newGalleryNameForUpload: String = ""
    @State private var showDeleteGalleryConfirm: Bool = false

    @State private var weatherLocationNameDraft: String = ""
    @State private var weatherLatitudeDraft: String = ""
    @State private var weatherLongitudeDraft: String = ""
    @State private var historyHighlightYearDraft: String = ""

    private enum ActiveSelection: Equatable {
        case gallery(UUID?) // nil = the implicit "All" tab
        case generated
        case localFolder
    }

    @State private var activeSelection: ActiveSelection = .gallery(nil)
    @State private var unlockPasswordDraft: String = ""
    @State private var unlockError: Bool = false

    @State private var newTabName: String = ""
    @State private var passwordDrafts: [UUID: String] = [:]
    @State private var selectedLocalFolderIndex: Int = 0
    @State private var lastUploadFailed: Bool = false
    @State private var showSuccessBadge: Bool = false
    @State private var localFolderPasswordDraft: String = ""
    @State private var localFolderPasswordError: Bool = false
    @State private var localFolderUnlocked: Bool = false
    @State private var showLocalFolderPasswordSetup: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            revealHiddenTabsShortcut

            header

            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.15))
                let previewImage = controller.localFolderCandidates.indices.contains(selectedLocalFolderIndex)
                    ? controller.localFolderCandidates[selectedLocalFolderIndex].image
                    : (controller.localFolderCandidates.first?.image ?? controller.previewImage)
                if let previewImage = previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }

                if showSuccessBadge {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Uploaded!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.95))
                    .cornerRadius(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 220)
            .onChange(of: controller.statusText) { text in
                if text.contains("✓ Displayed") {
                    showSuccessBadge = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            showSuccessBadge = false
                        }
                    }
                } else if text.contains("✗") {
                    showSuccessBadge = false
                }
            }

            if !controller.localFolderCandidates.isEmpty {
                Text("Pick one of 3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onChange(of: controller.localFolderCandidates.count) { _ in
                        selectedLocalFolderIndex = 0
                    }
            } else if let currentImagePath = controller.currentImagePath {
                Text(currentImagePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }

            if let deviceName = controller.deviceName {
                Text(deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.autoRandomEnabled, let next = controller.nextAutoRandomFireDate {
                Label("Next auto photo: \(next.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !controller.localFolderCandidates.isEmpty {
                localFolderPreviewControls
            } else if showSettings {
                settingsForm
            } else {
                controls
            }

            if !controller.statusText.isEmpty {
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(width: 300)
        .task {
            populateSettingsDrafts()
            if !settings.deviceIP.isEmpty {
                await controller.refreshCurrentPhoto()
                await controller.loadGalleries()
            } else {
                showSettings = true
            }
            populateSettingsDrafts() // pick up device values fetched above
            if slideshowGallery.isEmpty {
                slideshowGallery = controller.galleries.first ?? ""
            }
            if manageGallery.isEmpty {
                manageGallery = controller.galleries.first ?? ""
            }
        }
        .onChange(of: controller.galleries) { names in
            if slideshowGallery.isEmpty {
                slideshowGallery = names.first ?? ""
            }
            if manageGallery.isEmpty {
                manageGallery = names.first ?? ""
            }
        }
    }

    private func populateSettingsDrafts() {
        ipDraft = settings.deviceIP
        bleNameDraft = settings.bleDeviceName
        nasaApiKeyDraft = settings.nasaApiKey
        deviceNameDraft = controller.deviceName ?? ""
        maxIdleMinutesDraft = controller.maxIdleSeconds.map { String($0 / 60) } ?? ""
        sleepDurationHoursDraft = controller.sleepDurationSeconds.map { String($0 / 3600) } ?? ""
        wakeSensitivityDraft = controller.wakeSensitivity.map(String.init) ?? ""
        weatherLocationNameDraft = settings.weatherLocationName
        weatherLatitudeDraft = String(settings.weatherLatitude)
        weatherLongitudeDraft = String(settings.weatherLongitude)
        historyHighlightYearDraft = String(settings.historyHighlightYear)
    }

    private var header: some View {
        HStack {
            Text("Bloomin8")
                .font(.headline)
            Spacer()
            if let isAwake = controller.isDeviceAwake {
                awakeIndicator(isAwake: isAwake)
            }
            if let battery = controller.batteryPercent {
                batteryIndicator(percent: battery)
            }
            Button {
                showSettings.toggle()
                if showSettings {
                    populateSettingsDrafts()
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
        }
    }

    private func awakeIndicator(isAwake: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(isAwake ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(isAwake ? "Awake" : "Asleep")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func batteryIndicator(percent: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: batterySymbolName(for: percent))
            Text("\(percent)%")
        }
        .font(.caption)
        .foregroundStyle(batteryColor(for: percent))
    }

    private func batterySymbolName(for percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryColor(for percent: Int) -> Color {
        if percent <= 15 { return .red }
        if percent <= 30 { return .orange }
        return .secondary
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frame IP address")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. 192.168.1.42", text: $ipDraft)
                .textFieldStyle(.roundedBorder)

            Text("Bluetooth device name (for waking a sleeping frame)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. Office", text: $bleNameDraft)
                .textFieldStyle(.roundedBorder)

            Text("NASA API key (for Photo of the Day — defaults to the public demo key)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("DEMO_KEY", text: $nasaApiKeyDraft)
                .textFieldStyle(.roundedBorder)

            Divider()

            Group {
                DisclosureGroup("Manage Tabs (\(settings.tabs.count))") {
                    tabManagerView
                }
                DisclosureGroup("Upload / Download Photos") {
                    photoManagementSection
                }
                DisclosureGroup("Automatic Random Photo") {
                    autoRandomSection
                }
                DisclosureGroup("Device Settings") {
                    deviceSettingsSection
                }
                DisclosureGroup("Generated Content Settings") {
                    generatedContentSettingsSection
                }
            }

            Divider()

            HStack {
                Button("Cancel") { showSettings = false }
                Spacer()
                Button("Save & Connect") {
                    settings.deviceIP = ipDraft
                    settings.bleDeviceName = bleNameDraft
                    let trimmedKey = nasaApiKeyDraft.trimmingCharacters(in: .whitespaces)
                    settings.nasaApiKey = trimmedKey.isEmpty ? "DEMO_KEY" : trimmedKey
                    settings.weatherLocationName = weatherLocationNameDraft.trimmingCharacters(in: .whitespaces)
                    if let lat = Double(weatherLatitudeDraft) { settings.weatherLatitude = lat }
                    if let lon = Double(weatherLongitudeDraft) { settings.weatherLongitude = lon }
                    if let year = Int(historyHighlightYearDraft) { settings.historyHighlightYear = year }
                    showSettings = false
                    Task {
                        await controller.refreshCurrentPhoto()
                        await controller.loadGalleries()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ipDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Automatic random photo (AppSettings)

    private var autoRandomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically show a random photo", isOn: $settings.autoRandomEnabled)

            if settings.autoRandomEnabled {
                Picker("Frequency", selection: $settings.autoRandomInterval) {
                    ForEach(AutoRandomInterval.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if settings.autoRandomInterval == .daily {
                    DatePicker("At", selection: autoRandomDailyTimeBinding, displayedComponents: .hourAndMinute)
                }
            }
        }
    }

    private var autoRandomDailyTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = settings.autoRandomDailyMinute / 60
                components.minute = settings.autoRandomDailyMinute % 60
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings.autoRandomDailyMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    // MARK: - Device settings (pushed to the frame itself, not just local)

    private var deviceSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applied directly to the frame, not just saved locally.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Device name", text: $deviceNameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Auto-sleep after")
                    .font(.caption)
                TextField("min", text: $maxIdleMinutesDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Deep sleep every")
                    .font(.caption)
                TextField("hrs", text: $sleepDurationHoursDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Wake sensitivity")
                    .font(.caption)
                TextField("", text: $wakeSensitivityDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
            }

            Button("Update Device Settings") {
                Task {
                    await controller.updateDeviceSettings(
                        name: deviceNameDraft.trimmingCharacters(in: .whitespaces).isEmpty ? nil : deviceNameDraft,
                        sleepDurationSeconds: Int(sleepDurationHoursDraft).map { $0 * 3600 },
                        maxIdleSeconds: Int(maxIdleMinutesDraft).map { $0 * 60 },
                        wakeSensitivity: Int(wakeSensitivityDraft)
                    )
                    populateSettingsDrafts()
                }
            }
        }
    }

    // MARK: - Generated content settings (Weather location, History year)

    private var generatedContentSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Weather location name", text: $weatherLocationNameDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Latitude", text: $weatherLatitudeDraft)
                    .textFieldStyle(.roundedBorder)
                TextField("Longitude", text: $weatherLongitudeDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("History highlight year")
                    .font(.caption)
                TextField("1979", text: $historyHighlightYearDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            Text("If today has a historical event from this year, it's always shown first.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Upload / download photos (AppSettings)

    private var photoManagementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Crop landscape photos to fill the frame", isOn: $settings.cropLandscapePhotos)
            Text("Off: a landscape photo shows in full, with black bars above and below. On: it's cropped and centered to fill the whole screen instead. Portrait photos aren't affected.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            if !controller.galleries.isEmpty {
                Picker("Gallery", selection: $manageGallery) {
                    ForEach(controller.galleries, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            }

            TextField("or type a new gallery name to upload into", text: $newGalleryNameForUpload)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Upload Photos...") {
                    let urls = FilePicker.chooseImages()
                    guard !urls.isEmpty else { return }
                    let trimmedNew = newGalleryNameForUpload.trimmingCharacters(in: .whitespaces)
                    let targetGallery = trimmedNew.isEmpty ? manageGallery : trimmedNew
                    Task {
                        await controller.uploadPhotos(urls: urls, gallery: targetGallery)
                        newGalleryNameForUpload = ""
                    }
                }

                Button("Download Gallery...") {
                    guard !manageGallery.isEmpty, let folder = FilePicker.chooseFolder() else { return }
                    Task { await controller.downloadGallery(manageGallery, to: folder) }
                }
                .disabled(manageGallery.isEmpty)
            }

            HStack {
                Button("New Gallery") {
                    let name = newGalleryNameForUpload.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        await controller.createGallery(name: name)
                        newGalleryNameForUpload = ""
                    }
                }
                .disabled(newGalleryNameForUpload.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Creates an empty gallery using the name typed above")

                Button("Delete Gallery...", role: .destructive) {
                    showDeleteGalleryConfirm = true
                }
                .disabled(manageGallery.isEmpty)
            }
        }
        .alert("Delete '\(manageGallery)'?", isPresented: $showDeleteGalleryConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await controller.deleteGalleryOnDevice(manageGallery) }
            }
        } message: {
            Text("This removes the gallery and every photo in it from the frame. This can't be undone.")
        }
    }

    // MARK: - Tab management (AppSettings)

    private var tabManagerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tabs group galleries and can optionally require a password to view.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(settings.tabs) { tab in
                tabEditor(tab: tab)
            }

            HStack {
                TextField("New tab name", text: $newTabName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newTabName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    settings.tabs.append(GalleryTab(name: trimmed))
                    newTabName = ""
                }
                .disabled(newTabName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func tabEditor(tab: GalleryTab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tab.name).bold()
                Spacer()
                Button(role: .destructive) {
                    deleteTab(tab)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(controller.galleries, id: \.self) { name in
                    Toggle(name, isOn: tabMembershipBinding(tab: tab, gallery: name))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }

            passwordEditor(tab: tab)
            Divider()
        }
    }

    private func passwordEditor(tab: GalleryTab) -> some View {
        HStack {
            SecureField(tab.isLocked ? "New password" : "Set password", text: passwordDraftBinding(for: tab))
                .textFieldStyle(.roundedBorder)
            Button(tab.isLocked ? "Update" : "Lock") { setPassword(for: tab) }
                .disabled((passwordDrafts[tab.id] ?? "").isEmpty)
            if tab.isLocked {
                Button("Unlock") { removePassword(for: tab) }
            }
        }
    }

    private func passwordDraftBinding(for tab: GalleryTab) -> Binding<String> {
        Binding(
            get: { passwordDrafts[tab.id] ?? "" },
            set: { passwordDrafts[tab.id] = $0 }
        )
    }

    private func setPassword(for tab: GalleryTab) {
        guard let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let password = passwordDrafts[tab.id] ?? ""
        guard !password.isEmpty else { return }
        settings.tabs[index].passwordHash = PasswordHasher.hash(password)
        passwordDrafts[tab.id] = ""
        controller.unlockedTabIDs.remove(tab.id) // re-lock immediately under the new password
    }

    private func removePassword(for tab: GalleryTab) {
        guard let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        settings.tabs[index].passwordHash = nil
        controller.unlockedTabIDs.remove(tab.id)
    }

    private func deleteTab(_ tab: GalleryTab) {
        settings.tabs.removeAll { $0.id == tab.id }
        controller.unlockedTabIDs.remove(tab.id)
        if activeSelection == .gallery(tab.id) { activeSelection = .gallery(nil) }
    }

    // MARK: - Main controls

    private var controls: some View {
        VStack(spacing: 8) {
            galleryChecklist
            if case .gallery = activeSelection {
                weightingPicker
            }

            HStack(spacing: 8) {
                Button {
                    Task { await controller.refreshCurrentPhoto() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }

                Menu {
                    Button("Redisplay Photo") {
                        Task { await controller.redisplayCurrentPhoto() }
                    }
                    Button("Show Next") {
                        Task { await controller.showNextImage() }
                    }
                    Button("Wake Frame") {
                        Task { await controller.wakeFrame() }
                    }
                    Divider()
                    Button("Save Photo...") {
                        savePhoto()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More: redisplay, show next, wake frame, save photo")

                Button {
                    Task {
                        switch activeSelection {
                        case .gallery:
                            await controller.showRandomPhoto()
                        case .generated:
                            await controller.showRandomGeneratedContent()
                        case .localFolder:
                            controller.prepareLocalFolderCandidate()
                        }
                    }
                } label: {
                    Label("Random Photo", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRandomDisabled || controller.isBusy)
            }

            if case .gallery = activeSelection {
                slideshowControls
            }
        }
        .disabled(controller.isBusy)
    }

    private var slideshowControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Slideshow")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Gallery", selection: $slideshowGallery) {
                    ForEach(controller.galleries, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                TextField("min", text: $slideshowDurationDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Start") {
                    let minutes = Int(slideshowDurationDraft) ?? 5
                    Task { await controller.startSlideshow(gallery: slideshowGallery, durationSeconds: minutes * 60) }
                }
                .disabled(slideshowGallery.isEmpty)
                Button("Stop") {
                    Task { await controller.stopSlideshow() }
                }
            }
        }
    }

    // MARK: - Local folder preview (approve/skip/cancel before anything is sent)

    private var localFolderPreviewControls: some View {
        VStack(spacing: 8) {
            Text("Click to select, then Send")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(Array(controller.localFolderCandidates.enumerated()), id: \.offset) { index, candidate in
                    Button {
                        selectedLocalFolderIndex = index
                    } label: {
                        Image(nsImage: candidate.image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 60)
                            .clipped()
                            .cornerRadius(4)
                            .opacity(index == selectedLocalFolderIndex ? 1.0 : 0.6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(index == selectedLocalFolderIndex ? Color.blue : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(fileInfoTooltip(for: candidate))
                    .contextMenu {
                        Button("Open in Finder") {
                            NSWorkspace.shared.selectFile(candidate.fileURL.path, inFileViewerRootedAtPath: candidate.fileURL.deletingLastPathComponent().path)
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(candidate.fileURL.path, forType: .string)
                        }
                        Divider()
                        if settings.favoriteImagePaths.contains(candidate.fileURL.path) {
                            Button("Remove from Favorites", role: .destructive) {
                                settings.favoriteImagePaths.removeAll { $0 == candidate.fileURL.path }
                            }
                        } else {
                            Button("Add to Favorites") {
                                if !settings.favoriteImagePaths.contains(candidate.fileURL.path) {
                                    settings.favoriteImagePaths.append(candidate.fileURL.path)
                                }
                            }
                        }
                    }
                }
                Spacer()
            }

            if !settings.favoriteImagePaths.isEmpty {
                favoritesGrid
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    lastUploadFailed = false
                    controller.cancelLocalFolderCandidate()
                }
                .frame(maxWidth: .infinity)

                Button("Next") {
                    lastUploadFailed = false
                    selectedLocalFolderIndex = 0
                    controller.prepareLocalFolderCandidate()
                }
                .frame(maxWidth: .infinity)

                if lastUploadFailed {
                    Button("Retry") {
                        lastUploadFailed = false
                        if controller.localFolderCandidates.indices.contains(selectedLocalFolderIndex) {
                            Task {
                                await controller.confirmLocalFolderCandidate(controller.localFolderCandidates[selectedLocalFolderIndex])
                                if controller.statusText.contains("✓") {
                                    lastUploadFailed = false
                                } else if controller.statusText.contains("✗") {
                                    lastUploadFailed = true
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                } else {
                    Button("Send") {
                        if controller.localFolderCandidates.indices.contains(selectedLocalFolderIndex) {
                            Task {
                                await controller.confirmLocalFolderCandidate(controller.localFolderCandidates[selectedLocalFolderIndex])
                                if controller.statusText.contains("✗") {
                                    lastUploadFailed = true
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .disabled(controller.isBusy)
    }

    private static let favoriteThumbnailHeight: CGFloat = 40
    private static let favoriteGridSpacing: CGFloat = 4
    private static let favoriteVisibleRows = 5

    /// Height of `favoriteVisibleRows` thumbnails plus the gaps between them.
    private var favoritesGridMaxHeight: CGFloat {
        let rows = CGFloat(Self.favoriteVisibleRows)
        return rows * Self.favoriteThumbnailHeight + (rows - 1) * Self.favoriteGridSpacing
    }

    /// Favorites wrap into a scrollable grid rather than a single row — with
    /// more than a handful, a horizontal strip hides everything past the third
    /// one with no affordance saying so.
    private var favoritesGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Favorites (\(settings.favoriteImagePaths.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", role: .destructive) {
                    settings.favoriteImagePaths.removeAll()
                }
                .font(.caption2)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 52), spacing: Self.favoriteGridSpacing)],
                    spacing: Self.favoriteGridSpacing
                ) {
                    ForEach(settings.favoriteImagePaths, id: \.self) { path in
                        favoriteThumbnail(path: path)
                    }
                }
                .padding(.trailing, 2) // keep the scrollbar off the thumbnails
            }
            // Grows to five rows, then scrolls — past that the grid would
            // start pushing Send/Cancel off the bottom of the popover.
            .frame(maxHeight: favoritesGridMaxHeight)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(4)
    }

    private func favoriteThumbnail(path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        return Button {
            selectedLocalFolderIndex = -1 // Mark as favorite, not from current batch
            controller.prepareBrowsedImage(url: url)
        } label: {
            Group {
                if let image = loadFavoriteImage(path: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // File moved or deleted since it was favorited — still show
                    // a tile so it can be removed from the list.
                    ZStack {
                        Color.gray.opacity(0.2)
                        Image(systemName: "questionmark.square.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.favoriteThumbnailHeight)
            .clipped()
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .help(url.lastPathComponent)
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Divider()
            Button("Remove from Favorites", role: .destructive) {
                settings.favoriteImagePaths.removeAll { $0 == path }
            }
        }
    }

    private func loadFavoriteImage(path: String) -> NSImage? {
        if let cached = favoriteThumbnailCache.object(forKey: path as NSString) {
            return cached
        }
        let url = URL(fileURLWithPath: path)
        guard let cgImage = loadUprightCGImage(at: url, maxPixelSize: 150),
              let thumbnail = renderLetterboxed(cgImage: cgImage, width: 150, height: 150, background: .black)
        else { return nil }
        favoriteThumbnailCache.setObject(thumbnail, forKey: path as NSString)
        return thumbnail
    }

    private func fileInfoTooltip(for candidate: PhotoController.LocalFolderCandidate) -> String {
        let path = candidate.fileURL.path
        let filename = candidate.fileURL.lastPathComponent
        let format = candidate.fileURL.pathExtension.uppercased()
        let sizeKB = Int(candidate.jpegData.count / 1024)
        let image = candidate.image
        let dimensions = "\(Int(image.size.width))×\(Int(image.size.height))"

        return "\(filename)\n\(format) • \(sizeKB)KB • \(dimensions)\n\n\(path)"
    }

    private func savePhoto() {
        guard let data = controller.currentImageData else { return }
        let panel = NSSavePanel()
        panel.title = "Save Photo"
        panel.nameFieldStringValue = controller.currentImagePath.map { ($0 as NSString).lastPathComponent } ?? "photo.jpg"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private var isRandomDisabled: Bool {
        switch activeSelection {
        case .gallery:
            return settings.selectedGalleries.intersection(controller.availableGalleryNames).isEmpty
        case .generated:
            return settings.selectedContentSources.isEmpty
        case .localFolder:
            return settings.randomFolderPath.trimmingCharacters(in: .whitespaces).isEmpty || (settings.localFolderLocked && !localFolderUnlocked)
        }
    }

    private var galleryChecklist: some View {
        VStack(alignment: .leading, spacing: 4) {
            tabBar

            switch activeSelection {
            case .generated:
                contentSourceChecklist
            case .localFolder:
                if settings.localFolderLocked && !localFolderUnlocked {
                    localFolderPasswordPrompt
                } else {
                    localFolderSection
                }
            case .gallery:
                if let tab = activeGalleryTab, tab.isLocked, !controller.unlockedTabIDs.contains(tab.id) {
                    lockedTabPrompt(tab: tab)
                } else {
                    Text("Galleries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(activeTabGalleryNames, id: \.self) { name in
                            Toggle(name, isOn: gallerySelectionBinding(for: name))
                                .toggleStyle(.checkbox)
                        }
                        if activeTabGalleryNames.isEmpty {
                            Text("No galleries in this tab.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Generated content

    private var contentSourceChecklist: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Generated Content")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ContentSources.all, id: \.id) { source in
                    Toggle(source.displayName, isOn: contentSourceBinding(for: source.id))
                        .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Generates a fresh image and uploads it to that source's own gallery on the frame (e.g. \"NASA\", \"Fortune\").")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func contentSourceBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.selectedContentSources.contains(id) },
            set: { isOn in
                if isOn {
                    settings.selectedContentSources.insert(id)
                } else {
                    settings.selectedContentSources.remove(id)
                }
            }
        )
    }

    // MARK: - Local folder

    private var localFolderPasswordPrompt: some View {
        VStack(spacing: 8) {
            Text("Local Folder is Locked")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $localFolderPasswordDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    attemptLocalFolderUnlock()
                }
            if localFolderPasswordError {
                Text("Incorrect password.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Button("Unlock") {
                attemptLocalFolderUnlock()
            }
            .buttonStyle(.borderedProminent)
            .disabled(localFolderPasswordDraft.isEmpty)
        }
    }

    private func attemptLocalFolderUnlock() {
        guard let hash = settings.localFolderPasswordHash else {
            localFolderPasswordError = true
            return
        }
        let result = PasswordHasher.verify(localFolderPasswordDraft, against: hash)
        guard result.matched else {
            localFolderPasswordError = true
            return
        }
        if let upgraded = result.upgradedHash {
            settings.localFolderPasswordHash = upgraded
        }
        localFolderPasswordError = false
        localFolderPasswordDraft = ""
        localFolderUnlocked = true
    }

    private var localFolderPasswordSetupSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Set Local Folder Password")
                    .font(.headline)
                Spacer()
                Button("Close") { showLocalFolderPasswordSetup = false }
            }
            .padding()

            VStack(alignment: .leading, spacing: 8) {
                Text("Set a password to protect the Local Folder tab:")
                    .font(.caption)
                SecureField("Password", text: $localFolderPasswordDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Set Password") {
                    if !localFolderPasswordDraft.isEmpty {
                        settings.localFolderPasswordHash = PasswordHasher.hash(localFolderPasswordDraft)
                        settings.localFolderLocked = true
                        localFolderPasswordDraft = ""
                        showLocalFolderPasswordSetup = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(localFolderPasswordDraft.isEmpty)
            }
            .padding()

            Spacer()
        }
    }

    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Local Folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(settings.randomFolderPath.isEmpty ? "No folder selected" : settings.randomFolderPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose...") {
                    if let folder = FilePicker.chooseFolder(title: "Choose a Folder of Photos") {
                        settings.randomFolderPath = folder.path
                    }
                }
            }
            HStack {
                Button("Delete Random Gallery", role: .destructive) {
                    Task { await controller.deleteRandomGallery() }
                }
                .font(.caption)
                Spacer()
            }
            HStack {
                if settings.localFolderLocked {
                    Button("Unlock Folder") {
                        settings.localFolderLocked = false
                        settings.localFolderPasswordHash = nil
                        localFolderUnlocked = false
                        localFolderPasswordDraft = ""
                    }
                    .font(.caption)
                } else {
                    Button("Lock Folder") {
                        showLocalFolderPasswordSetup = true
                    }
                    .font(.caption)
                }
                Spacer()
            }
            Text("When you pick a random photo, you'll see 3 options to choose from.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            .sheet(isPresented: $showLocalFolderPasswordSetup) {
                localFolderPasswordSetupSheet
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabChip(name: "All", selection: .gallery(nil), isLocked: false)
                ForEach(settings.tabs.filter { !$0.isLocked || controller.showHiddenTabs }) { tab in
                    tabChip(
                        name: tab.name,
                        selection: .gallery(tab.id),
                        isLocked: tab.isLocked && !controller.unlockedTabIDs.contains(tab.id)
                    )
                }
                tabChip(name: "✨ Generated", selection: .generated, isLocked: false)
                if !settings.localFolderLocked || controller.showHiddenTabs {
                    tabChip(
                        name: "📁 Folder",
                        selection: .localFolder,
                        isLocked: settings.localFolderLocked && !localFolderUnlocked
                    )
                }
            }
        }
    }

    /// Invisible — exists purely to register the ⌘⇧L shortcut that reveals
    /// every hidden tab (locked gallery tabs and the locked Local Folder tab)
    /// without a visible control anyone could stumble onto.
    private var revealHiddenTabsShortcut: some View {
        Button("") {
            controller.showHiddenTabs.toggle()
            // Hiding the tabs again shouldn't leave a now-invisible one selected.
            if !controller.showHiddenTabs, settings.localFolderLocked, activeSelection == .localFolder {
                activeSelection = .gallery(nil)
                localFolderUnlocked = false
                localFolderPasswordDraft = ""
                localFolderPasswordError = false
                controller.cancelLocalFolderCandidate()
            }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func tabChip(name: String, selection: ActiveSelection, isLocked: Bool) -> some View {
        Button {
            activeSelection = selection
            unlockPasswordDraft = ""
            unlockError = false
            localFolderPasswordDraft = ""
            localFolderPasswordError = false
            localFolderUnlocked = false
            controller.cancelLocalFolderCandidate()
        } label: {
            HStack(spacing: 4) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                }
                Text(name)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(activeSelection == selection ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func lockedTabPrompt(tab: GalleryTab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("'\(tab.name)' is locked", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $unlockPasswordDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { attemptUnlock(tab, unlockError: $unlockError, unlockPasswordDraft: $unlockPasswordDraft) }
            if unlockError {
                Text("Incorrect password.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Button("Unlock") { attemptUnlock(tab, unlockError: $unlockError, unlockPasswordDraft: $unlockPasswordDraft) }
                .buttonStyle(.borderedProminent)
                .disabled(unlockPasswordDraft.isEmpty)
        }
    }

    private func attemptUnlock(_ tab: GalleryTab, unlockError: Binding<Bool>, unlockPasswordDraft: Binding<String>) {
        if controller.unlock(tab: tab, password: unlockPasswordDraft.wrappedValue) {
            unlockError.wrappedValue = false
            unlockPasswordDraft.wrappedValue = ""
        } else {
            unlockError.wrappedValue = true
        }
    }

    private var activeGalleryTab: GalleryTab? {
        guard case .gallery(let id?) = activeSelection else { return nil }
        return settings.tabs.first(where: { $0.id == id })
    }

    private var ungroupedGalleryNames: [String] {
        let assigned = Set(settings.tabs.flatMap { $0.galleryNames })
        return controller.galleries.filter { !assigned.contains($0) }
    }

    private var activeTabGalleryNames: [String] {
        if let tab = activeGalleryTab {
            return controller.galleries.filter { tab.galleryNames.contains($0) }
        } else {
            return ungroupedGalleryNames
        }
    }

    private var weightingPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Randomize by")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Randomize by", selection: $settings.randomWeighting) {
                ForEach(RandomWeighting.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private func gallerySelectionBinding(for gallery: String) -> Binding<Bool> {
        Binding(
            get: { settings.selectedGalleries.contains(gallery) },
            set: { isOn in
                if isOn {
                    settings.selectedGalleries.insert(gallery)
                } else {
                    settings.selectedGalleries.remove(gallery)
                }
            }
        )
    }

    private func tabMembershipBinding(tab: GalleryTab, gallery: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.tabs.first(where: { $0.id == tab.id })?.galleryNames.contains(gallery) ?? false
            },
            set: { isOn in
                guard let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                if isOn {
                    settings.tabs[index].galleryNames.insert(gallery)
                } else {
                    settings.tabs[index].galleryNames.remove(gallery)
                }
            }
        )
    }
}

extension ContentView {
    /// When the popover hosting this view closes, hide the hidden tabs again
    /// so a keyboard-revealed state doesn't linger for the next person who
    /// opens the popover. We can't use NSPopover's didClose delegate directly
    /// on a SwiftUI hosted view, so this hook is called from AppDelegate
    /// after detaching the popover's menu.
    func resetHiddenTabVisibility() {
        if controller.showHiddenTabs {
            controller.showHiddenTabs = false
        }
    }
}
