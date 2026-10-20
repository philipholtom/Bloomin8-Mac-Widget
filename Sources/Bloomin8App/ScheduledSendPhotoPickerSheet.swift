import Bloomin8Core
import AppKit
import SwiftUI

/// Picks one photo already on the frame — browsing by gallery, same listing
/// `LibraryModel`/`LibraryGrid` use for the sidebar — rather than a file on
/// this Mac. A scheduled send should revert the display to something
/// already living on the device, not upload a new file each time it fires.
struct ScheduledSendPhotoPickerSheet: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library: LibraryModel
    @State private var selectedGallery: String?

    init(settings: AppSettings, controller: PhotoController, onPick: @escaping (String) -> Void) {
        self.settings = settings
        self.controller = controller
        self.onPick = onPick
        _library = StateObject(wrappedValue: LibraryModel(settings: settings, controller: controller))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose a Photo Already on the Frame")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            if controller.galleries.isEmpty {
                Text("No galleries loaded yet — open a gallery in the sidebar first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Gallery", selection: gallerySelection) {
                    ForEach(controller.galleries, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                content
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .onAppear {
            if selectedGallery == nil {
                selectedGallery = controller.galleries.first
            }
            if let selectedGallery {
                library.load(.gallery(selectedGallery))
            }
        }
    }

    private var gallerySelection: Binding<String?> {
        Binding(
            get: { selectedGallery },
            set: { newValue in
                selectedGallery = newValue
                if let newValue { library.load(.gallery(newValue)) }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if library.isLoading && library.items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = library.loadError, library.items.isEmpty {
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(library.items) { item in
                        PhotoPickerCell(item: item, settings: settings)
                            .onTapGesture {
                                guard let devicePath = item.devicePath else { return }
                                onPick(devicePath)
                                dismiss()
                            }
                    }
                }
            }
        }
    }
}

private struct PhotoPickerCell: View {
    let item: LibraryItem
    @ObservedObject var settings: AppSettings
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
                if let image {
                    PrivacyImage(image, settings: settings, gallery: item.galleryName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .privacyBlur(settings: settings, gallery: item.galleryName)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .task(id: item.id) {
            guard image == nil, let devicePath = item.devicePath else { return }
            image = await DeviceThumbnailStore.shared.thumbnail(ip: settings.deviceIP, path: devicePath, maxPixelSize: 300)
        }
    }
}
