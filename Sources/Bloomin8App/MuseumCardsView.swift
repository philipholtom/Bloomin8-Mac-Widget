import Bloomin8Core
import AppKit
import SwiftUI
import os

/// Every museum card in one place: search them, filter by gallery or by
/// whether they were typed by hand, and edit or delete one beside the photo
/// it describes. These are the same cards the CrowPanel display shows.
struct MuseumCardsView: View {
    private static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "museum-cards")

    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    @ObservedObject private var store = MuseumCardStore.shared

    private enum Origin: String, CaseIterable, Identifiable {
        case all = "All"
        case edited = "Typed by hand"
        case automatic = "Automatic"
        var id: String { rawValue }
    }

    private struct Row: Identifiable {
        let path: String
        let gallery: String
        let filename: String
        let card: MuseumCard
        var id: String { path }
    }

    @State private var search = ""
    @State private var galleryFilter: String?
    @State private var origin: Origin = .all
    @State private var selectedPath: String?
    @State private var photo: NSImage?
    @State private var photoMessage: String?
    @State private var pendingDeletion: String?

    // MARK: - Data

    /// Cards whose gallery sits in a locked tab that hasn't been unlocked are
    /// left out entirely: their wording describes what's in them.
    private var visibleRows: [Row] {
        store.snapshot.cards.compactMap { path, card in
            let parts = path.split(separator: "/").map(String.init)
            let gallery = parts.count >= 2 ? parts[1] : "Other"
            guard settings.lockedTab(for: gallery, unlockedTabIDs: controller.unlockedTabIDs) == nil else { return nil }
            return Row(path: path, gallery: gallery, filename: parts.last ?? path, card: card)
        }
    }

    private var rows: [Row] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return visibleRows
            .filter { galleryFilter == nil || $0.gallery == galleryFilter }
            .filter {
                switch origin {
                case .all: return true
                case .edited: return $0.card.edited
                case .automatic: return !$0.card.edited
                }
            }
            .filter { row in
                needle.isEmpty || [row.card.title, row.card.place, row.card.date, row.card.camera, row.card.notes, row.filename, row.gallery]
                    .contains { $0.lowercased().contains(needle) }
            }
            .sorted {
                ($0.gallery.lowercased(), $0.card.title.lowercased(), $0.filename) < ($1.gallery.lowercased(), $1.card.title.lowercased(), $1.filename)
            }
    }

    private var galleries: [String] {
        Set(visibleRows.map(\.gallery)).sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listPane
                    .frame(minWidth: 320, idealWidth: 420)
                detailPane
                    .frame(minWidth: 320, idealWidth: 380)
            }
        }
        .onAppear { store.reload() }
        .alert("Delete this card?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let path = pendingDeletion {
                    // An empty card removes the entry.
                    MuseumCardStore.shared.save(MuseumCard(), for: path)
                    if selectedPath == path { selectedPath = nil }
                }
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the card text only. The photo stays on the frame, and a new card is filled in if you send it again.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Search cards", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Menu {
                Button("All galleries") { galleryFilter = nil }
                Divider()
                ForEach(galleries, id: \.self) { name in
                    Button(name) { galleryFilter = name }
                }
            } label: {
                Label(galleryFilter ?? "All galleries", systemImage: "rectangle.stack")
            }
            .fixedSize()

            Picker("Show", selection: $origin) {
                ForEach(Origin.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Spacer()

            Text("\(rows.count) of \(visibleRows.count) · \(visibleRows.filter(\.card.edited).count) typed by hand")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.fileLocation])
            } label: {
                Label("Show File", systemImage: "folder")
            }
            .help("Reveal the cards file in Finder — it's plain JSON")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - List

    private var listPane: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.below.photo")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(visibleRows.isEmpty ? "No museum cards yet." : "No cards match.")
                        .foregroundStyle(.secondary)
                    if visibleRows.isEmpty {
                        Text("A card is made automatically for each photo you send to the frame.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                            Divider()
                        }
                    }
                }
            }
        }
        .onChange(of: selectedPath) { path in
            Self.log.notice("selected card: \(path ?? "none", privacy: .public) of \(rows.count) rows")
        }
    }

    private func rowView(_ row: Row) -> some View {
        let isSelected = selectedPath == row.path
        let card = row.card
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(card.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if card.edited {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Typed by hand")
                }
            }
            let detail = [card.place, card.date, card.camera].filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !card.notes.isEmpty {
                Text(card.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("\(row.gallery) › \(row.filename)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        // Plain tap gesture, not Button — this project's established fix for
        // intermittent missed clicks in lists and grids on this OS.
        .onTapGesture { selectedPath = row.path }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let path = selectedPath, store.snapshot.cards[path] != nil {
            let gallery = path.split(separator: "/").dropFirst().first.map(String.init)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(gallery ?? "") › \((path as NSString).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    photoPreview(gallery: gallery)

                    MuseumCardEditor(path: path, localSourceURL: nil)
                        .id(path)

                    HStack {
                        Button {
                            Task { await controller.showImageAtPath(path) }
                        } label: {
                            Label("Show on Frame", systemImage: "paperplane")
                        }
                        .disabled(controller.isBusy || settings.deviceIP.isEmpty)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.doc")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            pendingDeletion = path
                        } label: {
                            Label("Delete Card…", systemImage: "trash")
                        }
                    }
                }
                .padding(14)
            }
            .task(id: path) { await loadPhoto(path: path) }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.below.photo")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Select a card to see its photo and edit it.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func photoPreview(gallery: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
            if let photo {
                PrivacyImage(photo, settings: settings, gallery: gallery)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .privacyBlur(settings: settings, gallery: gallery)
            } else if let photoMessage {
                Text(photoMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 220)
        .overlay(alignment: .topTrailing) {
            PrivacyBlurButton(settings: settings, gallery: gallery).padding(8)
        }
    }

    /// Fetches the photo from the frame for the selected card — only when the
    /// frame is awake, since its server is slow and shouldn't be woken or
    /// kept busy just to preview a list.
    private func loadPhoto(path: String) async {
        photo = nil
        photoMessage = nil
        guard !settings.deviceIP.isEmpty else { photoMessage = "No frame set up."; return }
        guard controller.isDeviceAwake == true else {
            photoMessage = "The frame is asleep, so its photo can't be shown here."
            return
        }
        let image = await DeviceThumbnailStore.shared.thumbnail(ip: settings.deviceIP, path: path, maxPixelSize: 700)
        guard !Task.isCancelled else { return }
        if let image { photo = image } else { photoMessage = "That photo isn't on the frame any more, or it didn't answer." }
    }
}
