import Bloomin8Core
import AppKit
import Charts
import SwiftUI

/// What the frame is showing right now, with the whole-frame actions that
/// aren't tied to one image in the library — laid out as a dashboard: the
/// photo and what you can do with it on the left; ways to show something
/// new, what's scheduled next, and what just happened on the right.
struct CurrentPhotoPane: View {
    @ObservedObject var controller: PhotoController
    @ObservedObject var settings: AppSettings
    @ObservedObject var scheduledSendManager: ScheduledSendManager
    @ObservedObject var scheduledContentManager: ScheduledContentManager
    @ObservedObject var photosMirrorManager: PhotosMirrorManager
    /// Opens Settings on the Automation page.
    let openAutomationSettings: () -> Void
    /// Opens the full Activity list.
    let openActivity: () -> Void

    @State private var slideshowGallery = ""
    @State private var slideshowMinutes = "5"
    @State private var showLocalFolderPicker = false
    @State private var showFavoritesPicker = false
    @State private var showRandomPhotoPicker = false
    @State private var showOnThisDayPicker = false
    @State private var batteryRange: BatteryRange = .week

    private enum BatteryRange: String, CaseIterable, Identifiable {
        case day = "24 hours"
        case week = "7 days"
        case month = "30 days"

        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .month: return 30 * 86_400
            }
        }
    }

    var body: some View {
        ScrollView {
            // Side by side when there's room, stacked when the window is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    photoColumn.frame(minWidth: 300, idealWidth: 400, maxWidth: 460)
                    cardsColumn.frame(minWidth: 320, maxWidth: .infinity)
                }
                .frame(minWidth: 700)

                // Stacked (narrow window): keep the photo at its side-by-side
                // size instead of stretching to the full window width.
                VStack(spacing: 22) {
                    photoColumn.frame(maxWidth: 460)
                    cardsColumn
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: controller.galleries) { names in
            if slideshowGallery.isEmpty { slideshowGallery = names.first ?? "" }
        }
        .sheet(isPresented: $showLocalFolderPicker) {
            LocalFolderCandidatePickerSheet(controller: controller)
        }
        .sheet(isPresented: $showFavoritesPicker) {
            LocalFolderCandidatePickerSheet(controller: controller, source: .favorites)
        }
        .sheet(isPresented: $showRandomPhotoPicker) {
            RandomPhotoPickerSheet(controller: controller)
        }
        .sheet(isPresented: $showOnThisDayPicker) {
            LocalFolderCandidatePickerSheet(controller: controller, source: .photosOnThisDay)
        }
    }

    // MARK: - Left: the photo and what to do with it

    /// Width over height of the preview box: the picture's own shape when one
    /// is loaded (so a landscape frame shows landscape), otherwise the frame's
    /// configured orientation. Not a fixed portrait 3:4.
    private var previewAspect: CGFloat {
        if let size = controller.previewImage?.size, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return CGFloat(settings.renderWidth) / CGFloat(max(1, settings.renderHeight))
    }

    private var photoColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.12))
                if let image = controller.previewImage {
                    PrivacyImage(image, settings: settings, gallery: controller.currentGalleryOnDevice, isLocalFile: controller.currentLocalSourceURL != nil)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .privacyBlur(settings: settings, gallery: controller.currentGalleryOnDevice, isLocalFile: controller.currentLocalSourceURL != nil)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text(settings.deviceIP.isEmpty ? "No frame configured" : "Nothing loaded yet")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(previewAspect, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                PrivacyBlurButton(settings: settings, gallery: controller.currentGalleryOnDevice, isLocalFile: controller.currentLocalSourceURL != nil)
                    .padding(10)
            }

            if let path = controller.currentImagePath {
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let gallery = controller.currentGalleryOnDevice {
                        Text("in \(gallery)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .help(path)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await controller.redisplayCurrentPhoto() }
                } label: {
                    Label("Redisplay", systemImage: "arrow.clockwise")
                }
                .disabled(controller.isBusy)
                .help("Send the current photo to the screen again")

                Button {
                    Task { await controller.showNextImage() }
                } label: {
                    Label("Next", systemImage: "forward")
                }
                .disabled(controller.isBusy)
                .help("Advance the frame's own slideshow or playlist by one")

                Button {
                    toggleCurrentImageFavorite()
                } label: {
                    Label(
                        isCurrentImageFavorited ? "Unfavorite" : "Favorite",
                        systemImage: isCurrentImageFavorited ? "star.slash" : "star"
                    )
                }
                .disabled(controller.currentLocalSourceURL == nil)
                .help(controller.currentLocalSourceURL == nil
                    ? "Only available for photos sent from Local Folder — Favorites is a bookmark list of local files"
                    : (isCurrentImageFavorited ? "Remove this photo from Favorites" : "Add this photo to Favorites"))

                Button {
                    savePhoto()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(controller.currentImageData == nil)
                .help("Save a copy of this photo to your Mac")
            }
            .controlSize(.regular)

            if let path = controller.currentImagePath {
                MuseumCardEditor(path: path, localSourceURL: controller.currentLocalSourceURL)
            }
        }
    }

    // MARK: - Right: cards

    private var cardsColumn: some View {
        VStack(spacing: 14) {
            showSomethingNewCard
            comingUpCard
            recentActivityCard
            batteryCard
            randomSourcesCard
            slideshowCard
        }
    }

    private var showSomethingNewCard: some View {
        GroupBox("Show something new") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button {
                    Task { await controller.showRandomPhoto() }
                } label: {
                    Label("Random photo", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isBusy)
                .help("Shows a random photo immediately, no preview step")

                Button {
                    showRandomPhotoPicker = true
                } label: {
                    Label("Random 3", systemImage: "square.grid.3x1.below.line.grid.1x2").frame(maxWidth: .infinity)
                }
                .disabled(controller.isBusy)
                .help("Picks 3 random photos to choose from, with Next for 3 more")

                Button {
                    Task { await controller.fireScheduledContent(ScheduledContent(sourceID: "apod", useToday: true)) }
                } label: {
                    Label("Today's NASA", systemImage: "moon.stars").frame(maxWidth: .infinity)
                }
                .disabled(controller.isBusy || settings.deviceIP.isEmpty)
                .help("Shows NASA's actual picture of the day, framed with its description")

                Button {
                    showOnThisDayPicker = true
                } label: {
                    Label("On this day", systemImage: "calendar").frame(maxWidth: .infinity)
                }
                .disabled(controller.isBusy)
                .help("Photos from your Photos library taken on today's date in earlier years — pick one of 3")

                Button {
                    showLocalFolderPicker = true
                } label: {
                    Label("From folder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .disabled(controller.isBusy || settings.randomFolderPath.isEmpty || isLocalFolderLocked)
                .help(localFolderButtonHelp)

                Button {
                    showFavoritesPicker = true
                } label: {
                    Label("From favourites", systemImage: "star").frame(maxWidth: .infinity)
                }
                .disabled(controller.isBusy || settings.favoriteImagePaths.isEmpty || isLocalFolderLocked)
                .help(settings.favoriteImagePaths.isEmpty
                    ? "No favourites yet"
                    : (isLocalFolderLocked ? "Favourites are locked — unlock them from the sidebar first" : "Picks 3 random favourites to choose from, with Next for 3 more"))
            }
            .controlSize(.large)
            .padding(8)
        }
    }

    private var comingUpCard: some View {
        GroupBox("Coming up") {
            VStack(alignment: .leading, spacing: 8) {
                if scheduleRows.isEmpty {
                    Text("Nothing scheduled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scheduleRows) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(row.title)
                                .lineLimit(1)
                            Spacer()
                            Text(row.when)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                Button("Set up schedules…", action: openAutomationSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private struct ScheduleRow: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let when: String
    }

    /// One row per schedule that is actually switched on and has a next time.
    private var scheduleRows: [ScheduleRow] {
        var rows: [ScheduleRow] = []
        if let content = settings.scheduledContent, content.isEnabled, let next = scheduledContentManager.nextFireDate {
            let source = ContentSources.all.first(where: { $0.id == content.sourceID })
            let suffix = (content.useToday && source is TodayContentSource) ? " (today's)" : ""
            let title = content.sourceID == ScheduledContent.onThisDayPhotosSourceID
                ? "On this day (Photos)"
                : (source?.displayName ?? "Generated picture") + suffix
            rows.append(ScheduleRow(id: "content", symbol: "sparkles", title: title, when: Self.describe(next)))
        }
        if let send = settings.scheduledSend, send.isEnabled, let next = scheduledSendManager.nextFireDate {
            let name = send.devicePath.isEmpty ? "Scheduled photo" : (send.devicePath as NSString).lastPathComponent
            rows.append(ScheduleRow(id: "send", symbol: "clock", title: name, when: Self.describe(next)))
        }
        if let mirror = settings.photosMirror, mirror.isEnabled, !mirror.albumID.isEmpty {
            let when = photosMirrorManager.isSyncing
                ? "Syncing…"
                : (photosMirrorManager.lastSyncDate.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Checks every 30 min")
            rows.append(ScheduleRow(id: "mirror", symbol: "arrow.triangle.2.circlepath.circle", title: "Mirror “\(mirror.albumTitle)”", when: when))
        }
        if settings.autoRandomEnabled, let next = controller.nextAutoRandomFireDate {
            rows.append(ScheduleRow(id: "auto", symbol: "arrow.triangle.2.circlepath", title: "Auto random photo", when: Self.describe(next)))
        }
        return rows
    }

    /// "Today 17:00", "Tomorrow 07:00", or "Mon 07:00".
    private static func describe(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    private var recentActivityCard: some View {
        GroupBox("Recent activity") {
            VStack(alignment: .leading, spacing: 8) {
                if controller.recentActivity.isEmpty {
                    Text("Nothing yet this session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.recentActivity.prefix(3)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(event.success ? Color.green : Color.red)
                                .frame(width: 18)
                            Text(event.message)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                Button("View all activity…", action: openActivity)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var batteryCard: some View {
        GroupBox("Battery") {
            VStack(alignment: .leading, spacing: 10) {
                let now = Date()
                let visible = controller.batterySamples.filter { now.timeIntervalSince($0.date) <= batteryRange.seconds }
                HStack(alignment: .firstTextBaseline) {
                    if let percent = controller.batteryPercent {
                        Text("\(percent)%")
                            .font(.title2.weight(.semibold))
                    }
                    if let days = BatteryHistory.daysRemaining(samples: controller.batterySamples, now: now) {
                        Text(days > 99 ? "more than 99 days left at the recent rate" : "about \(Int(days.rounded())) day\(Int(days.rounded()) == 1 ? "" : "s") left at the recent rate")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Range", selection: $batteryRange) {
                        ForEach(BatteryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 190)
                }

                if visible.count >= 2 {
                    Chart(visible) { sample in
                        AreaMark(x: .value("Time", sample.date), y: .value("Battery", sample.percent))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                        LineMark(x: .value("Time", sample.date), y: .value("Battery", sample.percent))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                        }
                    }
                    .chartXScale(domain: now.addingTimeInterval(-batteryRange.seconds)...now)
                    .frame(height: 110)
                } else {
                    Text(controller.batterySamples.isEmpty
                        ? "Readings appear here once the frame has been awake with the app open."
                        : "Not enough readings in this range yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Readings only come in while the frame is awake, so there are gaps while it sleeps.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    /// Which galleries "Random photo" draws from — kept, but collapsed to one
    /// line until you want to change it.
    private var randomSourcesCard: some View {
        GroupBox {
            DisclosureGroup("Random photo sources · \(settings.selectedGalleries.intersection(controller.availableGalleryNames).count) galleries") {
                let names = controller.availableGalleryNames.sorted()
                if names.isEmpty {
                    Text(controller.galleries.isEmpty ? "No galleries loaded yet." : "No unlocked galleries available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        // This is the same settings.selectedGalleries the
                        // widget's own checkboxes read and write — shared
                        // settings, so checking a gallery here also checks it
                        // there.
                        ForEach(names, id: \.self) { name in
                            Toggle(name, isOn: gallerySelectionBinding(for: name))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                        Picker("Randomize by", selection: $settings.randomWeighting) {
                            ForEach(RandomWeighting.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
            }
            .padding(8)
        }
    }

    private var slideshowCard: some View {
        GroupBox("Slideshow on the frame") {
            HStack(spacing: 8) {
                Picker("Gallery", selection: $slideshowGallery) {
                    ForEach(controller.galleries, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)

                TextField("min", text: $slideshowMinutes)
                    .frame(width: 44)
                Text("min").foregroundStyle(.secondary)

                Button("Start") {
                    let minutes = Int(slideshowMinutes) ?? 5
                    Task { await controller.startSlideshow(gallery: slideshowGallery, durationSeconds: minutes * 60) }
                }
                .disabled(slideshowGallery.isEmpty)

                Button("Stop") {
                    Task { await controller.stopSlideshow() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// Same lock Local Folder itself sits behind (see Sidebar's identical
    /// check) — this button reaches the same content from outside that
    /// view, so it needs the same gate rather than offering a side door
    /// around the password/Touch ID prompt.
    private var isLocalFolderLocked: Bool {
        settings.localFolderLocked && !controller.isLocalFolderUnlocked
    }

    private var localFolderButtonHelp: String {
        if settings.randomFolderPath.isEmpty { return "Choose a Local Folder in Settings first" }
        if isLocalFolderLocked { return "Local Folder is locked — unlock it from the sidebar first" }
        return "Picks 3 random photos from Local Folder to choose from"
    }

    private var isCurrentImageFavorited: Bool {
        guard let url = controller.currentLocalSourceURL else { return false }
        return settings.favoriteImagePaths.contains(url.path)
    }

    private func toggleCurrentImageFavorite() {
        guard let url = controller.currentLocalSourceURL else { return }
        if settings.favoriteImagePaths.contains(url.path) {
            settings.favoriteImagePaths.removeAll { $0 == url.path }
        } else {
            settings.favoriteImagePaths.append(url.path)
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

    private func savePhoto() {
        guard let data = controller.currentImageData else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (controller.currentImagePath as NSString?)?.lastPathComponent ?? "photo.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

/// The generated content sources, with the same checkbox model as the widget.
struct GeneratedPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var showPicker = false
    @State private var pickerSource: ContentSource = APODSource()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick which sources the frame can generate from. With more than one checked, Random picks between them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(ContentSources.all, id: \.id) { source in
                    HStack {
                        Toggle(source.displayName, isOn: Binding(
                            get: { settings.selectedContentSources.contains(source.id) },
                            set: { on in
                                if on { settings.selectedContentSources.insert(source.id) }
                                else { settings.selectedContentSources.remove(source.id) }
                            }
                        ))
                        Spacer()
                        // Plain .onTapGesture, not Button: this row's tap
                        // target showed the same intermittent missed-click
                        // behavior on this OS as the candidate picker grids
                        // (see ContentSourcePickerSheet/VideoFramePickerSheet)
                        // — a tap could fire against a stale target and open
                        // the picker for the wrong source (always the first
                        // row, APOD) instead of the one actually tapped.
                        Image(systemName: "eye")
                            .foregroundStyle(controller.isBusy ? .quaternary : .secondary)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !controller.isBusy else { return }
                                pickerSource = source
                                showPicker = true
                            }
                            .help("Preview a few \(source.displayName) options before sending one, instead of generating one blind")
                    }
                }

                Button {
                    Task { await controller.showRandomGeneratedContent() }
                } label: {
                    Label("Generate & Display", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.selectedContentSources.isEmpty || controller.isBusy)
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showPicker) {
            // .id(pickerSource.id) forces SwiftUI to treat each source as a
            // genuinely distinct view rather than reusing the previous
            // sheet's identity — without it, the sheet's own @State (and its
            // one-shot .task that fetches candidates) carried over from
            // whichever source was previewed last, so the title bar showed
            // the newly tapped source but the images were the previous
            // source's stale candidates until "Next" was pressed manually.
            ContentSourcePickerSheet(source: pickerSource, controller: controller)
                .id(pickerSource.id)
        }
    }
}
