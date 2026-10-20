import Bloomin8Core
import SwiftUI

/// Moves one or more images already on the frame into a different gallery.
/// The device has no move endpoint, so each image is downloaded, re-uploaded
/// to the destination gallery under its original filename, then deleted
/// from the source — sequential per item, so a failure partway through
/// leaves every other item either fully moved or completely untouched,
/// never half-uploaded-and-deleted.
struct MoveToGallerySheet: View {
    let items: [LibraryItem]
    @ObservedObject var controller: PhotoController
    /// The gallery being browsed, excluded from the destination list — moving
    /// something into the gallery it's already in isn't a real move.
    let excludedGalleryName: String?
    let onMoved: ([LibraryItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedGallery: String?
    @State private var isMoving = false
    @State private var progressText = ""
    @State private var failures: [String] = []

    private var destinationGalleries: [String] {
        controller.galleries.filter { $0 != excludedGalleryName }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(items.count == 1 ? "Move 1 Photo" : "Move \(items.count) Photos")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isMoving)
            }

            if destinationGalleries.isEmpty {
                Text("No other galleries to move into.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Move to", selection: $selectedGallery) {
                    Text("Choose a gallery…").tag(String?.none)
                    ForEach(destinationGalleries, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                .labelsHidden()
                .disabled(isMoving)

                if isMoving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !failures.isEmpty {
                    Text("Couldn't move: \(failures.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Move") { Task { await performMove() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedGallery == nil || isMoving)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func performMove() async {
        guard let destination = selectedGallery else { return }
        isMoving = true
        failures = []
        var moved: [LibraryItem] = []
        for (index, item) in items.enumerated() {
            guard let sourceGallery = item.galleryName else { continue }
            progressText = "Moving \(item.name) (\(index + 1)/\(items.count))…"
            let ok = await controller.moveDeviceImage(filename: item.name, from: sourceGallery, to: destination)
            if ok {
                moved.append(item)
            } else {
                failures.append(item.name)
            }
        }
        isMoving = false
        onMoved(moved)
        if failures.isEmpty {
            dismiss()
        }
        // Leaves the sheet open on a partial failure so the still-visible
        // status text and failure list explain what happened, rather than
        // silently closing on an incomplete move.
    }
}
