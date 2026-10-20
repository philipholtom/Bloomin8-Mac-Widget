import Bloomin8Core
import SwiftUI

/// Edits the museum card for whatever's on the frame — the label the CrowPanel
/// e-paper display shows next to it. Filled in automatically from the photo's
/// EXIF when it's sent; anything typed here wins over that from then on.
struct MuseumCardEditor: View {
    /// The photo's path on the frame, which is what cards are keyed by.
    let path: String
    /// The original file, when the photo was sent from this Mac, so the card
    /// can be refilled from its metadata.
    let localSourceURL: URL?

    @State private var card = MuseumCard()
    @State private var savedCard = MuseumCard()
    @State private var isFilling = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                field("Title", text: $card.title, prompt: "Morning at the Shrine")
                field("Place", text: $card.place, prompt: "Fushimi Inari Taisha, Kyoto, Japan")
                field("Date", text: $card.date, prompt: "14 March 2024")
                field("Camera", text: $card.camera, prompt: "iPhone 15 Pro · 24 mm")
                field("Notes", text: $card.notes, prompt: "Anything else for the label")

                HStack {
                    if let url = localSourceURL {
                        Button {
                            Task { await fill(from: url) }
                        } label: {
                            Label("Fill from Photo", systemImage: "wand.and.stars")
                        }
                        .disabled(isFilling)
                        .help("Replace these fields with the date, place and camera from the original photo")
                    }
                    if isFilling { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Revert") { card = savedCard }
                        .disabled(card == savedCard)
                    Button("Save") {
                        MuseumCardStore.shared.save(card, for: path)
                        savedCard = card
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(card == savedCard)
                }
            }
            .padding(4)
        } label: {
            Label("Museum card", systemImage: "text.below.photo")
                .help("Shown on the CrowPanel display beside the frame")
        }
        .onAppear { load(path: path) }
        // Uses the NEW path handed to this closure: reading `path` from the
        // view inside it gave the previous card's path on this SDK, so
        // clicking from one card to the next left the editor showing the
        // card before it (and a Save would have written it under the new one).
        .onChange(of: path) { newPath in load(path: newPath) }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func load(path: String) {
        let stored = MuseumCardStore.shared.card(for: path) ?? MuseumCard()
        card = stored
        savedCard = stored
    }

    private func fill(from url: URL) async {
        guard let metadata = PhotoMetadata.read(from: url) else { return }
        isFilling = true
        defer { isFilling = false }
        var filled = await MuseumCardBuilder.card(from: metadata)
        filled.notes = card.notes
        card = filled
    }
}
