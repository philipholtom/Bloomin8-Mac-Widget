import Bloomin8Core
import Photos
import SwiftUI

/// How a photo's museum card will look on the CrowPanel display, shown in
/// the inspector under Send to Frame: the card already saved for a photo on
/// the frame, or one built from the photo's metadata for anything else.
struct MuseumCardPreview: View {
    let item: LibraryItem

    @State private var card: MuseumCard?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Museum card")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let card, !card.isEmpty {
                    cardText(card)
                } else {
                    Text("No date, place or camera details in this photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Black on white, like the e-paper it previews.
            .background(Color.white)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35)))
        }
        .task(id: item.id) { await load() }
    }

    /// Mirrors the CrowPanel layout: the title (or the date when there's no
    /// title) as the headline, then place, date · camera, and notes.
    @ViewBuilder
    private func cardText(_ card: MuseumCard) -> some View {
        let hasTitle = !card.title.isEmpty
        let headline = hasTitle ? card.title : card.date
        let detail = (hasTitle ? [card.date, card.camera] : [card.camera]).filter { !$0.isEmpty }.joined(separator: " · ")
        if !headline.isEmpty {
            Text(headline).font(.system(size: 14, weight: .bold))
        }
        if !card.place.isEmpty {
            Text(card.place).font(.system(size: 12))
        }
        if !detail.isEmpty {
            Text(detail).font(.system(size: 12))
        }
        if !card.notes.isEmpty {
            Text(card.notes).font(.system(size: 11, design: .serif))
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        card = nil
        if let devicePath = item.devicePath {
            card = MuseumCardStore.shared.card(for: devicePath)
        } else if let url = item.url {
            if let meta = await Task.detached(priority: .utility, operation: { PhotoMetadata.read(from: url) }).value {
                card = await MuseumCardBuilder.card(from: meta)
            }
        } else if let assetID = item.photoAssetID, let meta = Self.metadata(forAsset: assetID) {
            card = await MuseumCardBuilder.card(from: meta)
        }
    }

    /// The date and location Photos already knows for an asset — avoids
    /// downloading the full original (possibly from iCloud) just to preview.
    /// The card made when the photo is actually sent reads the original's
    /// EXIF, which also has the camera.
    private static func metadata(forAsset assetID: String) -> PhotoMetadata? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        var meta = PhotoMetadata()
        meta.dateTaken = asset.creationDate
        if let location = asset.location {
            meta.latitude = location.coordinate.latitude
            meta.longitude = location.coordinate.longitude
        }
        return meta
    }
}
