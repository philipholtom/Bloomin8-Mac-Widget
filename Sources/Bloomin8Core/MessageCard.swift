import AppKit
import CoreImage

/// What to put on a hand-made card: a message, a Wi-Fi sign-in code, or a QR
/// code for a link or any text.
public struct CardContent: Equatable {
    public enum Kind: String, CaseIterable, Identifiable {
        case message = "Message"
        case wifi = "Wi-Fi"
        case qr = "Link / text"
        public var id: String { rawValue }
    }

    public enum WifiSecurity: String, CaseIterable, Identifiable {
        case wpa = "WPA / WPA2 / WPA3"
        case wep = "WEP"
        case none = "No password"
        public var id: String { rawValue }
        var code: String {
            switch self {
            case .wpa: return "WPA"
            case .wep: return "WEP"
            case .none: return "nopass"
            }
        }
    }

    public var kind: Kind = .message
    /// Small heading at the top (optional for a message).
    public var title = ""
    /// The message itself.
    public var body = ""
    /// A line under the message, e.g. a signature.
    public var footer = ""

    public var wifiName = ""
    public var wifiPassword = ""
    public var wifiSecurity: WifiSecurity = .wpa
    public var wifiHidden = false
    /// Print the password in words under the code, for guests who can't scan.
    public var showPassword = true

    /// For a link / text code.
    public var qrText = ""
    public var caption = ""

    public init() {}

    /// Whether there's enough to draw something.
    public var isReady: Bool {
        switch kind {
        case .message: return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .wifi: return !wifiName.trimmingCharacters(in: .whitespaces).isEmpty
        case .qr: return !qrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The text a QR scanner reads.
    public var qrPayload: String? {
        switch kind {
        case .message: return nil
        case .wifi: return WifiQR.payload(ssid: wifiName, password: wifiPassword, security: wifiSecurity, hidden: wifiHidden)
        case .qr: return qrText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The museum card to file with the picture. Never holds a Wi-Fi password.
    public var museumCard: MuseumCard {
        var card = MuseumCard()
        switch kind {
        case .message:
            card.title = title.isEmpty ? "Message" : title
            card.notes = APODSource.leadSentences(of: body, upTo: 150)
        case .wifi:
            card.title = title.isEmpty ? "Wi-Fi" : title
            card.notes = "Scan to join \(wifiName)."
        case .qr:
            card.title = title.isEmpty ? "QR code" : title
            card.notes = caption
        }
        return card.normalized()
    }
}

/// The text format phones read from a Wi-Fi QR code:
/// `WIFI:T:WPA;S:name;P:password;H:true;;`
public enum WifiQR {
    public static func payload(ssid: String, password: String, security: CardContent.WifiSecurity, hidden: Bool) -> String {
        var text = "WIFI:T:\(security.code);S:\(escape(ssid));"
        if security != .none { text += "P:\(escape(password));" }
        if hidden { text += "H:true;" }
        return text + ";"
    }

    /// `\ ; , : "` have meaning in the format, so they're escaped with a backslash.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\;,:\"".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

public enum QRCode {
    private static let context = CIContext()

    /// The code as a 1-pixel-per-module image, or nil if the text is too long.
    static func modules(for text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // "Q" repairs up to ~25% damage: a little extra size for a code that
        // still reads after a scuff or glare on the screen.
        filter.setValue("Q", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

/// Draws a `CardContent` as a picture for the frame: black on white, which
/// the e-ink panel shows most crisply. Portrait stacks the parts; landscape
/// puts the code on the left and the words on the right.
public enum CardRenderer {
    private static let ink = NSColor.black
    private static let soft = NSColor(white: 0.35, alpha: 1)
    private static let accent = NSColor(red: 0.72, green: 0.1, blue: 0.08, alpha: 1)

    public static func render(_ content: CardContent, width: Int, height: Int) -> NSImage? {
        ImageCanvas.render(width: width, height: height) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let canvas = CGSize(width: width, height: height)
            switch content.kind {
            case .message: drawMessage(content, canvas: canvas)
            case .wifi, .qr: drawCode(content, canvas: canvas)
            }
        }
    }

    // MARK: - Message

    private static func drawMessage(_ content: CardContent, canvas: CGSize) {
        let margin = canvas.width * 0.08
        var top = margin
        var bottom = canvas.height - margin
        let titleText = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleText.isEmpty {
            let size = canvas.width * 0.05
            drawLines([titleText.uppercased()], font: font(size, bold: true), color: accent, centerX: canvas.width / 2, top: top, lineHeight: size * 1.3)
            top += size * 1.3 + margin * 0.5
        }
        let footerText = content.footer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !footerText.isEmpty {
            let size = canvas.width * 0.04
            bottom -= size * 1.3
            drawLines([footerText], font: font(size), color: soft, centerX: canvas.width / 2, top: bottom, lineHeight: size * 1.3)
            bottom -= margin * 0.5
        }
        let body = content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keeps the writer's own line breaks, fitting each paragraph's wrap to the width.
        let fit = fittingBody(body, maxWidth: canvas.width - margin * 2, maxHeight: bottom - top, upper: canvas.width * 0.2)
        let blockHeight = CGFloat(fit.lines.count) * fit.lineHeight
        drawLines(fit.lines, font: fit.font, color: ink, centerX: canvas.width / 2,
                  top: top + max(0, (bottom - top - blockHeight) / 2), lineHeight: fit.lineHeight)
    }

    /// The biggest font where the wrapped message fits the box.
    private static func fittingBody(_ text: String, maxWidth: CGFloat, maxHeight: CGFloat, upper: CGFloat) -> (font: NSFont, lines: [String], lineHeight: CGFloat) {
        func attempt(_ size: CGFloat) -> (NSFont, [String], CGFloat) {
            let f = font(size, bold: true)
            let lines = text.components(separatedBy: .newlines).flatMap { paragraph -> [String] in
                paragraph.trimmingCharacters(in: .whitespaces).isEmpty ? [""] : wrapTextToWidth(paragraph, font: f, maxWidth: maxWidth)
            }
            return (f, lines, size * 1.25)
        }
        var size = upper
        while size > 28 {
            let candidate = attempt(size)
            if CGFloat(candidate.1.count) * candidate.2 <= maxHeight { return candidate }
            size -= 4
        }
        return attempt(28)
    }

    // MARK: - Wi-Fi and link codes

    private static func drawCode(_ content: CardContent, canvas: CGSize) {
        let landscape = canvas.width > canvas.height
        let margin = min(canvas.width, canvas.height) * 0.07
        guard let payload = content.qrPayload, let modules = QRCode.modules(for: payload) else {
            drawLines(["That's too long for a QR code."], font: font(canvas.width * 0.05, bold: true), color: accent,
                      centerX: canvas.width / 2, top: canvas.height / 2, lineHeight: canvas.width * 0.07)
            return
        }

        // Where the code and the words go.
        let codeArea: CGRect
        let textArea: CGRect
        if landscape {
            let side = canvas.height - margin * 2
            codeArea = CGRect(x: margin, y: margin, width: side, height: side)
            textArea = CGRect(x: margin * 2 + side, y: margin, width: canvas.width - side - margin * 3, height: canvas.height - margin * 2)
        } else {
            let side = min(canvas.width - margin * 2, canvas.height * 0.5)
            codeArea = CGRect(x: (canvas.width - side) / 2, y: canvas.height * 0.27, width: side, height: side)
            textArea = CGRect(x: margin, y: margin, width: canvas.width - margin * 2, height: canvas.height - margin * 2)
        }

        drawQR(modules, in: codeArea)

        // The words: heading, then (portrait) above the code or (landscape) beside it.
        var lines: [(text: String, font: NSFont, color: NSColor)] = []
        let wide = textArea.width
        let big = min(wide * (landscape ? 0.17 : 0.13), 120)
        let heading = content.title.trimmingCharacters(in: .whitespaces)
        switch content.kind {
        case .wifi:
            lines.append((heading.isEmpty ? "Wi-Fi" : heading, font(big, bold: true), ink))
            lines.append((content.wifiName, font(big * 0.55), accent))
        default:
            if !heading.isEmpty { lines.append((heading, font(big, bold: true), ink)) }
        }

        var under: [(text: String, font: NSFont, color: NSColor)] = []
        let small = big * 0.5
        switch content.kind {
        case .wifi:
            under.append(("Scan to join", font(small), soft))
            if content.showPassword, content.wifiSecurity != .none, !content.wifiPassword.isEmpty {
                under.append(("Password", font(small * 0.75), soft))
                under.append((content.wifiPassword, NSFont.monospacedSystemFont(ofSize: small * 1.05, weight: .semibold), ink))
            }
        default:
            let caption = content.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            under.append((caption.isEmpty ? "Scan me" : caption, font(small), soft))
        }

        if landscape {
            // All the words in one block, centred beside the code.
            let all = lines + under
            let heights = all.map { $0.font.pointSize * 1.3 }
            let total = heights.reduce(0, +)
            var y = textArea.minY + max(0, (textArea.height - total) / 2)
            for (index, line) in all.enumerated() {
                drawFitted(line.text, font: line.font, color: line.color, in: textArea, y: y)
                y += heights[index]
            }
        } else {
            var y = textArea.minY
            for line in lines {
                drawFitted(line.text, font: line.font, color: line.color, in: textArea, y: y)
                y += line.font.pointSize * 1.3
            }
            var below = codeArea.maxY + margin * 0.6
            for line in under {
                drawFitted(line.text, font: line.font, color: line.color, in: textArea, y: below)
                below += line.font.pointSize * 1.3
            }
        }
    }

    /// Draws the code with square, whole-pixel modules and a quiet border.
    private static func drawQR(_ modules: CGImage, in area: CGRect) {
        let count = CGFloat(modules.width)
        let border: CGFloat = 4
        let scale = max(1, floor(min(area.width, area.height) / (count + border * 2)))
        let side = (count + border * 2) * scale
        let origin = CGPoint(x: (area.midX - side / 2).rounded(), y: (area.midY - side / 2).rounded())
        NSColor.white.setFill()
        NSRect(x: origin.x, y: origin.y, width: side, height: side).fill()
        guard let context = NSGraphicsContext.current else { return }
        let previous = context.imageInterpolation
        context.imageInterpolation = .none
        drawImage(NSImage(cgImage: modules, size: NSSize(width: count, height: count)),
                  in: NSRect(x: origin.x + border * scale, y: origin.y + border * scale, width: count * scale, height: count * scale))
        context.imageInterpolation = previous
    }

    // MARK: - Text

    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    }

    /// One line centred in `area`, shrunk until it fits the width.
    private static func drawFitted(_ text: String, font: NSFont, color: NSColor, in area: CGRect, y: CGFloat) {
        var f = font
        var size = font.pointSize
        while size > 14, (text as NSString).size(withAttributes: [.font: f]).width > area.width {
            size -= 2
            f = NSFont(descriptor: font.fontDescriptor, size: size) ?? f
        }
        drawLines([text], font: f, color: color, centerX: area.midX, top: y, lineHeight: size * 1.3)
    }

    /// Lines centred on `centerX`, from `top` down (top-left origin, text counter-flipped).
    private static func drawLines(_ lines: [String], font: NSFont, color: NSColor, centerX: CGFloat, top: CGFloat, lineHeight: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var y = top
        for line in lines {
            if !line.isEmpty, let context = NSGraphicsContext.current?.cgContext {
                let text = line as NSString
                let size = text.size(withAttributes: attrs)
                context.saveGState()
                context.translateBy(x: centerX - size.width / 2, y: y + (lineHeight + size.height) / 2 - (lineHeight - size.height) / 2)
                context.scaleBy(x: 1, y: -1)
                text.draw(at: .zero, withAttributes: attrs)
                context.restoreGState()
            }
            y += lineHeight
        }
    }
}
