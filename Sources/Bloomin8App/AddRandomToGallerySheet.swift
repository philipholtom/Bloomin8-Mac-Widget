import Bloomin8Core
import SwiftUI

/// Browse Files → "Add to Gallery…": uploads N random photos from the folder
/// being browsed (and its subfolders) into a gallery on the frame, so the
/// frame's own slideshow of that gallery can run without this Mac. Photos
/// already in the gallery from an earlier run are skipped, so running it
/// again adds *new* ones rather than duplicates.
struct AddRandomToGallerySheet: View {
    let folder: URL
    @ObservedObject var controller: PhotoController
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case setup
        case working
        case done
    }

    /// Stands in for "a gallery that doesn't exist yet" in the picker.
    private static let newGalleryChoice = "\u{1}new-gallery"
    private static let countOptions = [5, 10, 20, 30, 50, 100]

    @State private var phase: Phase = .setup
    @State private var count = 20
    @State private var selectedGallery = ""
    @State private var newGalleryName = ""
    @AppStorage("addRandomLastGallery") private var lastGallery = ""

    /// Locked galleries stay out of the list (and so out of reach) unless
    /// they've been unlocked this session — same rule as the sidebar.
    private var availableGalleries: [String] {
        controller.galleries.filter { settings.lockedTab(for: $0, unlockedTabIDs: controller.unlockedTabIDs) == nil }
    }

    private var targetGallery: String {
        selectedGallery == Self.newGalleryChoice
            ? newGalleryName.trimmingCharacters(in: .whitespaces)
            : selectedGallery
    }

    /// Uploads run at roughly 4 seconds a photo on this frame.
    private var estimate: String {
        let seconds = count * 4
        return seconds < 90 ? "about \(seconds) seconds" : "about \(Int((Double(seconds) / 60).rounded())) minutes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Random Photos to a Gallery")
                .font(.headline)

            switch phase {
            case .setup: setupContent
            case .working: workingContent
            case .done: doneContent
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if settings.deviceIP.isEmpty { return }
            selectedGallery = availableGalleries.contains(lastGallery) ? lastGallery : (availableGalleries.first ?? Self.newGalleryChoice)
            newGalleryName = folder.lastPathComponent
        }
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Picks random photos from “\(folder.lastPathComponent)” and its subfolders and uploads them to the frame. Run it again for more — photos already in the gallery are skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("How many", selection: $count) {
                ForEach(Self.countOptions, id: \.self) { Text("\($0) photos").tag($0) }
            }

            Picker("Gallery", selection: $selectedGallery) {
                ForEach(availableGalleries, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New gallery…").tag(Self.newGalleryChoice)
            }

            if selectedGallery == Self.newGalleryChoice {
                TextField("New gallery name", text: $newGalleryName)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Takes \(estimate).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(count) Photos") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetGallery.isEmpty || settings.deviceIP.isEmpty)
            }
        }
    }

    private var workingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(controller.statusText.isEmpty ? "Working…" : controller.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.statusText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func start() {
        let gallery = targetGallery
        guard !gallery.isEmpty else { return }
        lastGallery = gallery
        phase = .working
        Task {
            await controller.addRandomPhotos(from: folder, count: count, to: gallery)
            phase = .done
        }
    }
}
