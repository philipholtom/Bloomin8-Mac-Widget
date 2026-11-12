import Bloomin8Core
import AppKit
import SwiftUI

/// Make a card by hand and put it on the frame: a message, a Wi-Fi sign-in QR
/// code, or a QR code for any link or text. Drawn black on white, which the
/// e-ink panel shows most crisply.
struct MessageCardView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var content = CardContent()
    @State private var preview: NSImage?
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $content.kind) {
                        ForEach(CardContent.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch content.kind {
                    case .message: messageFields
                    case .wifi: wifiFields
                    case .qr: qrFields
                    }

                    HStack {
                        Button("Show on Frame") {
                            guard let jpeg = renderJPEG() else { return }
                            Task { await controller.showCardImage(jpeg: jpeg, card: content.museumCard) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!content.isReady || controller.isBusy)
                        Button("Save Image…") { saveImage() }
                            .disabled(!content.isReady)
                    }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Cards are kept in a “Messages” gallery on the frame. They stay there until you delete them, so remove a Wi-Fi card from that gallery when it's no longer wanted. Anything on the frame can be read by anyone in the room.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .frame(width: 360)

            Divider()

            VStack {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12))
                    if let preview, content.isReady {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .shadow(radius: 2)
                    } else {
                        Text("Fill in the details to see the card.").foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(CGFloat(settings.renderWidth) / CGFloat(max(1, settings.renderHeight)), contentMode: .fit)
                .padding(24)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: content) {
            // A beat after the last keystroke, so typing doesn't redraw every letter.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, content.isReady else { preview = nil; return }
            let snapshot = content
            let width = settings.renderWidth, height = settings.renderHeight
            preview = await Task.detached(priority: .userInitiated) {
                CardRenderer.render(snapshot, width: width, height: height)
            }.value
        }
    }

    // MARK: - Fields

    private var messageFields: some View {
        Group {
            field("Heading (optional)", text: $content.title, prompt: "e.g. Note")
            VStack(alignment: .leading, spacing: 4) {
                Text("Message").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $content.body)
                    .font(.body)
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
            field("Signed (optional)", text: $content.footer, prompt: "e.g. Love, Phil")
        }
    }

    private var wifiFields: some View {
        Group {
            field("Heading", text: $content.title, prompt: "Wi-Fi")
            field("Network name", text: $content.wifiName, prompt: "exactly as it appears")
            if content.wifiSecurity != .none {
                field("Password", text: $content.wifiPassword, prompt: "")
            }
            Picker("Security", selection: $content.wifiSecurity) {
                ForEach(CardContent.WifiSecurity.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Hidden network", isOn: $content.wifiHidden)
            if content.wifiSecurity != .none {
                Toggle("Show the password in words too", isOn: $content.showPassword)
            }
        }
    }

    private var qrFields: some View {
        Group {
            field("Heading (optional)", text: $content.title, prompt: "e.g. Our photos")
            field("Link or text", text: $content.qrText, prompt: "https://…")
            field("Under the code", text: $content.caption, prompt: "Scan me")
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Output

    private func renderJPEG() -> Data? {
        guard let image = CardRenderer.render(content, width: settings.renderWidth, height: settings.renderHeight),
              let jpeg = ImageCanvas.jpegData(image) else {
            message = "Couldn't draw the card."
            return nil
        }
        return jpeg
    }

    private func saveImage() {
        guard let image = CardRenderer.render(content, width: settings.renderWidth, height: settings.renderHeight),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Card.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            message = "Saved \(url.lastPathComponent)."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
