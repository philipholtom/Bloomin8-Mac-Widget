import Foundation
import Combine
import os

public enum RandomWeighting: String, CaseIterable, Identifiable {
    case perPhoto
    case perGallery

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .perPhoto: return "Photo"
        case .perGallery: return "Gallery"
        }
    }
}

public enum AutoRandomInterval: String, Codable, CaseIterable, Identifiable {
    case hourly
    case daily

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hourly: return "Every Hour"
        case .daily: return "Daily"
        }
    }
}

/// How this specific frame is physically mounted — not discoverable from
/// `/deviceInfo`, which always reports the same native panel resolution
/// (e.g. 1200x1600) regardless of orientation. The frame's own firmware
/// instead rotates whatever's uploaded 90° at display time based on the
/// uploaded filename's `_P`/`_L` suffix (see `AppSettings.renderWidth`/
/// `renderHeight` and `PhotoController.orientedFilename`), so this has to
/// be a setting the user tells the app, per frame.
public enum FrameOrientation: String, Codable, CaseIterable, Identifiable {
    case portrait
    case landscape

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

public final class AppSettings: ObservableObject {
    /// `Bundle.main.bundleIdentifier`, not a hardcoded string: this file is
    /// shared by both products, so the subsystem needs to resolve to
    /// whichever one is actually running for `log stream` filtering to
    /// mean anything (unlike BLEWaker, which hardcodes the widget's
    /// subsystem even though it's shared code too — a pre-existing
    /// inconsistency, not a pattern worth repeating here).
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pholtom.blooming8", category: "keychain")

    /// Both products read and write one store, so the frame IP, tabs,
    /// favorites and passwords stay in sync no matter which one you configure.
    ///
    /// A plain suite name rather than a `group.*` App Group: real App Groups
    /// need the `com.apple.security.application-groups` entitlement, which in
    /// turn needs a Developer ID signing identity. Neither product is
    /// sandboxed, so a shared suite lands in
    /// ~/Library/Preferences/com.pholtom.blooming8.shared.plist and is
    /// readable by both without any entitlement.
    public static let suiteName = "com.pholtom.blooming8.shared"

    private let defaults: UserDefaults

    // MARK: - Frame profiles

    /// Every frame this app knows about. Always has at least one entry —
    /// enforced at init (migrating pre-multi-frame settings into a single
    /// profile if none exist yet) and on delete (refusing to remove the
    /// last one).
    @Published public var frameProfiles: [FrameProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(frameProfiles) {
                defaults.set(data, forKey: "frameProfiles")
            }
        }
    }

    /// Which profile every per-frame property below reads and writes
    /// through. Falls back to the first profile if it ever points at one
    /// that no longer exists (e.g. right after that profile was deleted).
    @Published public var activeFrameProfileID: UUID {
        didSet { defaults.set(activeFrameProfileID.uuidString, forKey: "activeFrameProfileID") }
    }

    /// The active frame's profile as currently stored on disk. A process
    /// only sees its own edits live, so the always-on widget would otherwise
    /// run schedules from whatever the windowed app had saved when the
    /// widget launched.
    public func storedActiveProfile() -> FrameProfile? {
        guard let data = defaults.data(forKey: "frameProfiles"),
              let profiles = try? JSONDecoder().decode([FrameProfile].self, from: data) else { return nil }
        let activeID = defaults.string(forKey: "activeFrameProfileID").flatMap(UUID.init(uuidString:))
        return profiles.first(where: { $0.id == activeID }) ?? profiles.first
    }

    private var activeProfileIndex: Int {
        frameProfiles.firstIndex(where: { $0.id == activeFrameProfileID }) ?? 0
    }

    private var activeProfile: FrameProfile {
        frameProfiles.indices.contains(activeProfileIndex) ? frameProfiles[activeProfileIndex] : FrameProfile()
    }

    private func mutateActiveProfile(_ transform: (inout FrameProfile) -> Void) {
        guard frameProfiles.indices.contains(activeProfileIndex) else { return }
        var profile = frameProfiles[activeProfileIndex]
        transform(&profile)
        frameProfiles[activeProfileIndex] = profile
    }

    /// Adds a new, blank profile and switches to it immediately — a fresh
    /// frame is more likely to be what you want to configure next than
    /// stay looking at the one you just finished setting up.
    public func addFrameProfile(name: String) {
        let profile = FrameProfile(name: name)
        frameProfiles.append(profile)
        activeFrameProfileID = profile.id
    }

    /// Removes a profile (and its remote-push token from the secret store). Refuses
    /// to remove the last remaining profile — the app always needs
    /// somewhere for its per-frame settings to live — and switches to the
    /// first remaining profile if the active one was removed.
    public func deleteFrameProfile(_ id: UUID) {
        guard frameProfiles.count > 1, let index = frameProfiles.firstIndex(where: { $0.id == id }) else { return }
        SecretStore.delete(account: Self.einkshotTokenAccount(for: id))
        for tab in frameProfiles[index].tabs {
            SecretStore.delete(account: GalleryTab.keychainAccount(for: tab.id))
        }
        frameProfiles.remove(at: index)
        if activeFrameProfileID == id {
            activeFrameProfileID = frameProfiles[0].id
        }
    }

    public func renameFrameProfile(_ id: UUID, to newName: String) {
        guard let index = frameProfiles.firstIndex(where: { $0.id == id }) else { return }
        frameProfiles[index].name = newName
    }

    // MARK: - Per-frame properties (proxy into the active profile)

    public var deviceIP: String {
        get { activeProfile.deviceIP }
        set { mutateActiveProfile { $0.deviceIP = newValue } }
    }
    /// The frame's native panel resolution, learned from `/deviceInfo`.
    /// Confirmed directly against two physical frames, one mounted portrait
    /// and one landscape: `/deviceInfo` reports the exact same width/height
    /// on both (same panel hardware) — this is NOT orientation-aware, so use
    /// `renderWidth`/`renderHeight` below for anything that actually renders
    /// onto the frame's canvas.
    public var frameWidth: Int {
        get { activeProfile.frameWidth }
        set { mutateActiveProfile { $0.frameWidth = newValue } }
    }
    public var frameHeight: Int {
        get { activeProfile.frameHeight }
        set { mutateActiveProfile { $0.frameHeight = newValue } }
    }
    /// How this specific frame is physically mounted — see
    /// `FrameOrientation`'s own doc comment for why this can't be learned
    /// from the device itself and has to be set here.
    public var frameOrientation: FrameOrientation {
        get { activeProfile.frameOrientation }
        set { mutateActiveProfile { $0.frameOrientation = newValue } }
    }

    /// The canvas size to actually render onto — `frameWidth`/`frameHeight`
    /// swapped when `frameOrientation` is `.landscape`, since the frame's
    /// native panel is always the same physical shape (tall) regardless of
    /// mounting; the device itself rotates whatever's uploaded with an `_L`
    /// filename suffix 90° at display time (see
    /// `PhotoController.orientedFilename`) rather than accepting
    /// already-rotated pixel dimensions.
    public var renderWidth: Int { frameOrientation == .landscape ? frameHeight : frameWidth }
    public var renderHeight: Int { frameOrientation == .landscape ? frameWidth : frameHeight }

    public var selectedGalleries: Set<String> {
        get { activeProfile.selectedGalleries }
        set { mutateActiveProfile { $0.selectedGalleries = newValue } }
    }

    public var bleDeviceName: String {
        get { activeProfile.bleDeviceName }
        set { mutateActiveProfile { $0.bleDeviceName = newValue } }
    }

    public var tabs: [GalleryTab] {
        get { activeProfile.tabs }
        set {
            // Password hashes live in the secret store, not this profile's JSON —
            // keep it in sync here, in the one place tabs actually
            // change, rather than scattering writes across every call site
            // that mutates a tab's password.
            for tab in newValue {
                let account = GalleryTab.keychainAccount(for: tab.id)
                if let hash = tab.passwordHash {
                    SecretStore.write(hash, account: account)
                } else {
                    SecretStore.delete(account: account)
                }
            }
            // A tab that existed before but not anymore (deleted) would
            // otherwise leave its stored hash orphaned forever.
            let currentIDs = Set(newValue.map(\.id))
            for removed in activeProfile.tabs where !currentIDs.contains(removed.id) {
                SecretStore.delete(account: GalleryTab.keychainAccount(for: removed.id))
            }
            mutateActiveProfile { $0.tabs = newValue }
        }
    }

    public var autoRandomEnabled: Bool {
        get { activeProfile.autoRandomEnabled }
        set { mutateActiveProfile { $0.autoRandomEnabled = newValue } }
    }
    public var autoRandomInterval: AutoRandomInterval {
        get { activeProfile.autoRandomInterval }
        set { mutateActiveProfile { $0.autoRandomInterval = newValue } }
    }
    /// Minutes since midnight (local time), only used when autoRandomInterval == .daily.
    public var autoRandomDailyMinute: Int {
        get { activeProfile.autoRandomDailyMinute }
        set { mutateActiveProfile { $0.autoRandomDailyMinute = newValue } }
    }

    public var selectedContentSources: Set<String> {
        get { activeProfile.selectedContentSources }
        set { mutateActiveProfile { $0.selectedContentSources = newValue } }
    }

    /// When true, a landscape source photo is cropped and centered to fill
    /// the frame's canvas instead of being letterboxed. Portrait and square
    /// sources are unaffected either way — they don't have the "tiny photo
    /// between two black bars" problem this exists to fix.
    public var cropLandscapePhotos: Bool {
        get { activeProfile.cropLandscapePhotos }
        set { mutateActiveProfile { $0.cropLandscapePhotos = newValue } }
    }

    /// List of favorite image file paths marked by the user.
    public var favoriteImagePaths: [String] {
        get { activeProfile.favoriteImagePaths }
        set { mutateActiveProfile { $0.favoriteImagePaths = newValue } }
    }

    /// One photo scheduled to send at a fixed time on chosen days — see
    /// `ScheduledSend`.
    public var scheduledSend: ScheduledSend? {
        get { activeProfile.scheduledSend }
        set { mutateActiveProfile { $0.scheduledSend = newValue } }
    }

    /// A frame gallery kept in step with a Photos album — see `PhotosMirror`.
    public var photosMirror: PhotosMirror? {
        get { activeProfile.photosMirror }
        set { mutateActiveProfile { $0.photosMirror = newValue } }
    }

    /// A generated picture shown on a schedule — see `ScheduledContent`.
    public var scheduledContent: ScheduledContent? {
        get { activeProfile.scheduledContent }
        set { mutateActiveProfile { $0.scheduledContent = newValue } }
    }

    /// Bearer token for this frame's separate remote-push relay API
    /// ("einkshot" — see `EinkshotClient`), for sending a photo over the
    /// internet rather than the local network. Lives in the secret store (`SecretStore`), keyed by
    /// the active profile's id — not part of `FrameProfile`'s own JSON, the
    /// same reasoning as `GalleryTab.passwordHash`.
    public var einkshotToken: String? {
        get { SecretStore.read(account: Self.einkshotTokenAccount(for: activeFrameProfileID)) }
        set {
            let account = Self.einkshotTokenAccount(for: activeFrameProfileID)
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                SecretStore.write(newValue, account: account)
            } else {
                SecretStore.delete(account: account)
            }
            // Doesn't go through `frameProfiles` (secret-store-backed, not
            // JSON), so nothing else triggers a republish for SwiftUI here.
            objectWillChange.send()
        }
    }

    private static func einkshotTokenAccount(for profileID: UUID) -> String {
        "einkshotDeviceToken.\(profileID.uuidString)"
    }

    // MARK: - Mac-wide properties (shared across every frame profile)

    @Published public var randomWeighting: RandomWeighting {
        didSet { defaults.set(randomWeighting.rawValue, forKey: "randomWeighting") }
    }
    /// NASA APOD API key. Defaults to NASA's public shared demo key (rate-limited);
    /// stored locally only, never committed to the repo.
    @Published public var nasaApiKey: String {
        didSet { defaults.set(nasaApiKey, forKey: "nasaApiKey") }
    }
    @Published public var weatherLocationName: String {
        didSet { defaults.set(weatherLocationName, forKey: "weatherLocationName") }
    }
    @Published public var weatherLatitude: Double {
        didSet { defaults.set(weatherLatitude, forKey: "weatherLatitude") }
    }
    @Published public var weatherLongitude: Double {
        didSet { defaults.set(weatherLongitude, forKey: "weatherLongitude") }
    }
    /// The year format_history_text/create_history_art always surfaces first
    /// if present — a personal touch from the original script (likely a
    /// birth year), kept configurable rather than silently hardcoded.
    @Published public var historyHighlightYear: Int {
        didSet { defaults.set(historyHighlightYear, forKey: "historyHighlightYear") }
    }
    /// A folder on this Mac to pick random photos from for the "Local Folder"
    /// tab. Stored as a plain path — the app isn't sandboxed, so no
    /// security-scoped bookmark is needed to keep reading it after relaunch.
    /// Mac-wide rather than per-frame: it's this Mac's own files, not
    /// anything about a particular device.
    @Published public var randomFolderPath: String {
        didSet { defaults.set(randomFolderPath, forKey: "randomFolderPath") }
    }

    /// The folder the Browse Files tab currently has open — remembered
    /// between launches, but independent of `randomFolderPath`: Browse Files
    /// lets you navigate to (and reopen) any folder on this Mac, not just the
    /// one configured for Local Folder/Favorites/auto-random. Empty means
    /// "fall back to randomFolderPath", so it still has somewhere sensible to
    /// start the first time.
    @Published public var browseFilesRootPath: String {
        didSet { defaults.set(browseFilesRootPath, forKey: "browseFilesRootPath") }
    }

    /// Whether the Local Folder tab is password protected. Mac-wide for the
    /// same reason as `randomFolderPath` above.
    @Published public var localFolderLocked: Bool {
        didSet { defaults.set(localFolderLocked, forKey: "localFolderLocked") }
    }

    /// Hash of the Local Folder password (nil if not locked). Lives in
    /// the secret store, not this UserDefaults suite — the suite's own doc comment
    /// above explains why it can't have real access-group protection
    /// (no App Groups entitlement without a paid Developer ID), which is
    /// exactly why a password hash shouldn't sit in it as plain text.
    @Published public var localFolderPasswordHash: String? {
        didSet {
            if let localFolderPasswordHash {
                SecretStore.write(localFolderPasswordHash, account: Self.localFolderPasswordAccount)
            } else {
                SecretStore.delete(account: Self.localFolderPasswordAccount)
            }
        }
    }

    private static let localFolderPasswordAccount = "localFolderPasswordHash"

    /// When true, unlock prompts (gallery tabs, Local Folder/Favorites) try
    /// Touch ID first and only fall back to the password field if it's
    /// unavailable or fails. The password stays the real secret either way —
    /// this only changes whether biometrics offer a faster path to it.
    @Published public var useTouchIDForLocks: Bool {
        didSet { defaults.set(useTouchIDForLocks, forKey: "useTouchIDForLocks") }
    }

    /// Whether the museum-card server (port 8738, for a CrowPanel display) is
    /// running. On by default; people without a CrowPanel can turn it off.
    /// Both products read this from the shared defaults, so one switch covers
    /// the app and the widget.
    @Published public var cardServerEnabled: Bool {
        didSet { defaults.set(cardServerEnabled, forKey: "cardServerEnabled") }
    }

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        AppSettings.migrateLegacyDefaultsIfNeeded(into: defaults)

        // Built into local variables first, not assigned to `self` directly:
        // `frameProfiles` has a `didSet`, and Swift won't allow reading a
        // property with an observer back (`frameProfiles.contains`/`[0]`
        // below) until every stored property has been given a value — the
        // same restriction `tabs` used to hit before it moved into this
        // struct. Assigning both `self.frameProfiles` and
        // `self.activeFrameProfileID` once, at the end, from these locals
        // sidesteps it entirely.
        let resolvedProfiles: [FrameProfile]
        if let data = defaults.data(forKey: "frameProfiles"),
           let decoded = try? JSONDecoder().decode([FrameProfile].self, from: data),
           !decoded.isEmpty {
            resolvedProfiles = decoded
        } else {
            // First run after multi-frame support shipped (or a fresh
            // install): build one profile from whatever flat per-frame keys
            // already exist under the old single-frame scheme, so an
            // existing install doesn't come back up with a blank frame IP,
            // no tabs and no schedule.
            //
            // The App and Widget are separate processes that each construct
            // their own `AppSettings` independently — if both launch around
            // the same moment, both can see no `frameProfiles` yet and both
            // race to migrate. Using a fixed id here (rather than a fresh
            // random `UUID()`) makes that harmless: both processes compute
            // the same profile from the same underlying legacy keys, so
            // whichever writes last leaves equivalent data either way,
            // instead of one process's profile silently orphaning the
            // other's — confirmed hitting this exact race directly (App and
            // Widget launched together), which left `activeFrameProfileID`
            // pointing at a profile that no longer existed. (Harmless in
            // practice: `activeFrameProfileID`'s own resolution below falls
            // back to the first profile when its stored id doesn't match,
            // so this is defense in depth, not a fix for actual data loss.)
            let profile = AppSettings.legacyProfile(from: defaults, id: Self.legacyProfileID)
            resolvedProfiles = [profile]
            if let legacyToken = SecretStore.read(account: "einkshotDeviceToken") {
                SecretStore.write(legacyToken, account: Self.einkshotTokenAccount(for: profile.id))
            }
        }

        let resolvedActiveID: UUID
        if let idString = defaults.string(forKey: "activeFrameProfileID"), let id = UUID(uuidString: idString),
           resolvedProfiles.contains(where: { $0.id == id }) {
            resolvedActiveID = id
        } else {
            resolvedActiveID = resolvedProfiles[0].id
        }
        frameProfiles = resolvedProfiles
        activeFrameProfileID = resolvedActiveID

        if let raw = defaults.string(forKey: "randomWeighting"),
           let weighting = RandomWeighting(rawValue: raw) {
            randomWeighting = weighting
        } else {
            randomWeighting = .perPhoto
        }

        nasaApiKey = defaults.string(forKey: "nasaApiKey") ?? "DEMO_KEY"
        weatherLocationName = defaults.string(forKey: "weatherLocationName") ?? ""
        weatherLatitude = defaults.object(forKey: "weatherLatitude") != nil
            ? defaults.double(forKey: "weatherLatitude") : 0
        weatherLongitude = defaults.object(forKey: "weatherLongitude") != nil
            ? defaults.double(forKey: "weatherLongitude") : 0
        historyHighlightYear = defaults.object(forKey: "historyHighlightYear") != nil
            ? defaults.integer(forKey: "historyHighlightYear") : 1979
        randomFolderPath = defaults.string(forKey: "randomFolderPath") ?? ""
        browseFilesRootPath = defaults.string(forKey: "browseFilesRootPath") ?? ""
        localFolderLocked = defaults.bool(forKey: "localFolderLocked")
        if let fromStore = SecretStore.read(account: Self.localFolderPasswordAccount) {
            Self.log.notice("localFolderPasswordHash: read from the secret store")
            localFolderPasswordHash = fromStore
        } else if let legacy = defaults.string(forKey: "localFolderPasswordHash") {
            // One-time migration: this was sitting in the shared
            // UserDefaults suite as plain text before password hashes
            // moved to the secret store.
            Self.log.notice("localFolderPasswordHash: migrating legacy UserDefaults value into the secret store")
            SecretStore.write(legacy, account: Self.localFolderPasswordAccount)
            defaults.removeObject(forKey: "localFolderPasswordHash")
            localFolderPasswordHash = legacy
        } else {
            localFolderPasswordHash = nil
        }
        useTouchIDForLocks = defaults.bool(forKey: "useTouchIDForLocks")
        cardServerEnabled = defaults.object(forKey: "cardServerEnabled") as? Bool ?? true

        // `frameProfiles`'s own didSet does NOT fire for the assignment
        // above: Swift skips property observers when a property is set
        // inside its own initializer. Without this, a first-run migration
        // (or a tab whose hash just migrated out of the decoded blob) would
        // never actually get persisted until something unrelated touched
        // `frameProfiles` again — possibly never. Redone here, now that
        // every stored property (including `defaults` itself) is set and
        // `self` can be used. Same reasoning `tabs` used to need before it
        // moved inside `frameProfiles`.
        if let data = try? JSONEncoder().encode(frameProfiles) {
            defaults.set(data, forKey: "frameProfiles")
        }
        defaults.set(activeFrameProfileID.uuidString, forKey: "activeFrameProfileID")
    }

    /// Fixed id for the one profile created by migrating pre-multi-frame
    /// settings — see the migration race comment where this is used.
    private static let legacyProfileID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    /// Builds one `FrameProfile` from the flat per-frame keys this app used
    /// before multi-frame support existed, so upgrading doesn't lose an
    /// existing configuration.
    private static func legacyProfile(from defaults: UserDefaults, id: UUID) -> FrameProfile {
        let deviceIP = defaults.string(forKey: "deviceIP") ?? ""
        var profile = FrameProfile(name: deviceIP.isEmpty ? "My Frame" : deviceIP)
        profile.id = id
        profile.deviceIP = deviceIP
        profile.bleDeviceName = defaults.string(forKey: "bleDeviceName") ?? "Office"
        profile.frameWidth = defaults.object(forKey: "frameWidth") != nil ? defaults.integer(forKey: "frameWidth") : 1200
        profile.frameHeight = defaults.object(forKey: "frameHeight") != nil ? defaults.integer(forKey: "frameHeight") : 1600
        if let raw = defaults.string(forKey: "frameOrientation"), let orientation = FrameOrientation(rawValue: raw) {
            profile.frameOrientation = orientation
        }
        if let stored = defaults.stringArray(forKey: "selectedGalleries") {
            profile.selectedGalleries = Set(stored)
        } else if let legacy = defaults.string(forKey: "selectedGallery"), !legacy.isEmpty {
            // Migrate from the old single-gallery setting.
            profile.selectedGalleries = [legacy]
        }
        if let data = defaults.data(forKey: "galleryTabs"),
           let decoded = try? JSONDecoder().decode([GalleryTab].self, from: data) {
            profile.tabs = decoded
        }
        profile.autoRandomEnabled = defaults.bool(forKey: "autoRandomEnabled")
        if let raw = defaults.string(forKey: "autoRandomInterval"),
           let interval = AutoRandomInterval(rawValue: raw) {
            profile.autoRandomInterval = interval
        }
        if defaults.object(forKey: "autoRandomDailyMinute") != nil {
            profile.autoRandomDailyMinute = defaults.integer(forKey: "autoRandomDailyMinute")
        }
        if let stored = defaults.stringArray(forKey: "selectedContentSources") {
            profile.selectedContentSources = Set(stored)
        }
        profile.cropLandscapePhotos = defaults.bool(forKey: "cropLandscapePhotos")
        profile.favoriteImagePaths = defaults.stringArray(forKey: "favoriteImagePaths") ?? []
        if let data = defaults.data(forKey: "scheduledSend"),
           let decoded = try? JSONDecoder().decode(ScheduledSend.self, from: data) {
            profile.scheduledSend = decoded
        }
        return profile
    }

    /// The widget stored everything in the standard domain before the app
    /// existed. Copy that across on first run against the shared suite so an
    /// existing install doesn't come back up with a blank frame IP, no tabs
    /// and no favorites.
    private static func migrateLegacyDefaultsIfNeeded(into defaults: UserDefaults) {
        let marker = "didMigrateLegacyDefaults"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)

        let legacy = UserDefaults.standard
        let keys = [
            "deviceIP", "selectedGallery", "selectedGalleries", "randomWeighting",
            "bleDeviceName", "galleryTabs", "autoRandomEnabled", "autoRandomInterval",
            "autoRandomDailyMinute", "nasaApiKey", "selectedContentSources",
            "weatherLocationName", "weatherLatitude", "weatherLongitude",
            "historyHighlightYear", "randomFolderPath", "favoriteImagePaths",
            "localFolderLocked", "localFolderPasswordHash", "useTouchIDForLocks"
        ]
        for key in keys {
            guard let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
    }
}

extension AppSettings {
    /// The tab a gallery belongs to that's still locked (its password hasn't
    /// been entered this session), if any. `unlockedTabIDs` lives on
    /// `PhotoController`, not here, since it's per-process runtime state,
    /// not a persisted setting — callers pass it in.
    public func lockedTab(for galleryName: String, unlockedTabIDs: Set<UUID>) -> GalleryTab? {
        tabs.first {
            $0.isLocked && !unlockedTabIDs.contains($0.id) && $0.galleryNames.contains(galleryName)
        }
    }
}
