import Bloomin8Core
import AppKit
import SwiftUI

/// Photos handed to the app from outside it — Finder's right-click
/// "Send to Frame" service, Open With, or dropped on the Dock icon. Held here
/// (rather than passed straight to a view) because they arrive through
/// AppKit callbacks that have no connection to the SwiftUI window.
@MainActor
final class IncomingFiles: ObservableObject {
    static let shared = IncomingFiles()
    @Published var urls: [URL] = []
}

/// Asks what to do with photos received from Finder: for one photo, show it
/// on the frame now, crop it first, or file it in a gallery; for several,
/// upload them all to a gallery.
struct IncomingFilesSheet: View {
    let urls: [URL]
    @ObservedObject var controller: PhotoController
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case choose
        case gallery
        case working
        case done
    }

    private static let newGalleryChoice = "\u{1}new-gallery"

    @State private var stage: Stage = .choose
    @State private var preview: NSImage?
    @State private var showCrop = false
    @State private var selectedGallery = ""
    @State private var newGalleryName = ""
    @AppStorage("addRandomLastGallery") private var lastGallery = ""

    private var isSingle: Bool { urls.count == 1 }

    private var availableGalleries: [String] {
        controller.galleries.filter { settings.lockedTab(for: $0, unlockedTabIDs: controller.unlockedTabIDs) == nil }
    }

    private var targetGallery: String {
        selectedGallery == Self.newGalleryChoice
            ? newGalleryName.trimmingCharacters(in: .whitespaces)
            : selectedGallery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isSingle ? "Send “\(urls[0].lastPathComponent)” to the Frame" : "Send \(urls.count) Photos to the Frame")
                .font(.headline)

            switch stage {
            case .choose: chooseContent
            case .gallery: galleryContent
            case .working: workingContent
            case .done: doneContent
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            if isSingle {
                preview = await ThumbnailStore.shared.thumbnail(for: urls[0], maxPixelSize: 900)
            } else {
                stage = .gallery
            }
            selectedGallery = availableGalleries.contains(lastGallery) ? lastGallery : (availableGalleries.first ?? Self.newGalleryChoice)
        }
        .sheet(isPresented: $showCrop) {
            CropSheet(
                imageURL: urls[0],
                canvasAspect: Double(settings.renderWidth) / Double(settings.renderHeight)
            ) { region in
                stage = .working
                Task {
                    await controller.sendCropped(fileURL: urls[0], crop: region)
                    stage = .done
                }
            }
        }
    }

    private var chooseContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add to a Gallery…") { stage = .gallery }
                Button("Crop & Send…") { showCrop = true }
                Button("Show on Frame") { sendNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Gallery", selection: $selectedGallery) {
                ForEach(availableGalleries, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New gallery…").tag(Self.newGalleryChoice)
            }

            if selectedGallery == Self.newGalleryChoice {
                TextField("New gallery name", text: $newGalleryName)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Photos are added without being shown. Ones already in the gallery are replaced, not duplicated.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if isSingle {
                    Button("Back") { stage = .choose }
                }
                Button(isSingle ? "Add Photo" : "Add \(urls.count) Photos") { uploadToGallery() }
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

    /// The same render-and-send path a photo sent from Browse Files takes.
    private func sendNow() {
        stage = .working
        Task {
            controller.prepareBrowsedImage(url: urls[0])
            while controller.localFolderCandidates.isEmpty && controller.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let candidate = controller.localFolderCandidates.first {
                await controller.confirmLocalFolderCandidate(candidate)
                controller.cancelLocalFolderCandidate()
            }
            stage = .done
        }
    }

    private func uploadToGallery() {
        let gallery = targetGallery
        guard !gallery.isEmpty else { return }
        lastGallery = gallery
        stage = .working
        Task {
            await controller.uploadPhotos(urls: urls, gallery: gallery, deterministicNames: true)
            stage = .done
        }
    }
}
