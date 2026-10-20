import AppKit

/// Historical events for today's date, rendered as a vintage-style text
/// card. Ported from history_on_this_day.py, using the Wikimedia REST
/// "on this day" feed (free, no key, just a descriptive User-Agent).
public struct HistorySource: ContentSource {
    public let id = "history"
    public let displayName = "History on This Day"
    public let galleryName = "History"

    private let width = 1200
    private let height = 1600

    private struct ColorScheme {
        let background: NSColor
        let text: NSColor
        let accent: NSColor
    }

    private static let colorSchemes: [ColorScheme] = [
        ColorScheme(background: NSColor(red: 40/255, green: 35/255, blue: 25/255, alpha: 1),
                    text: NSColor(red: 220/255, green: 200/255, blue: 150/255, alpha: 1),
                    accent: NSColor(red: 200/255, green: 170/255, blue: 100/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 30/255, green: 15/255, blue: 50/255, alpha: 1),
                    text: NSColor(red: 200/255, green: 180/255, blue: 255/255, alpha: 1),
                    accent: NSColor(red: 180/255, green: 140/255, blue: 255/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 25/255, green: 20/255, blue: 15/255, alpha: 1),
                    text: NSColor(red: 200/255, green: 190/255, blue: 170/255, alpha: 1),
                    accent: NSColor(red: 150/255, green: 120/255, blue: 80/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 50/255, green: 40/255, blue: 30/255, alpha: 1),
                    text: NSColor(red: 210/255, green: 200/255, blue: 180/255, alpha: 1),
                    accent: NSColor(red: 170/255, green: 140/255, blue: 100/255, alpha: 1)),
    ]

    private struct WikimediaEvent: Decodable {
        let year: Int
        let text: String
    }
    private struct WikimediaOnThisDay: Decodable {
        let events: [WikimediaEvent]
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        let events = try await fetchEvents(highlightYear: settings.historyHighlightYear)
        guard let image = renderArt(events: events), let jpeg = ImageCanvas.jpegData(image) else {
            throw ContentSourceError.message("Couldn't render history image")
        }
        return jpeg
    }

    private func fetchEvents(highlightYear: Int) async throws -> [(year: Int, text: String)] {
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let url = URL(string: String(format: "https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/events/%02d/%02d", month, day))!

        var request = URLRequest(url: url)
        request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("Wikimedia API returned an error")
        }
        let decoded = try JSONDecoder().decode(WikimediaOnThisDay.self, from: data)
        guard !decoded.events.isEmpty else {
            throw ContentSourceError.message("No historical events found for today")
        }

        let highlighted = decoded.events.first { $0.year == highlightYear }
        let others = decoded.events.filter { $0.year != highlightYear }.sorted { $0.year > $1.year }

        var selected: [WikimediaEvent] = []
        if let highlighted {
            selected.append(highlighted)
            selected.append(contentsOf: others.prefix(4))
        } else {
            selected.append(contentsOf: others.prefix(5))
        }
        return selected.map { (year: $0.year, text: $0.text) }
    }

    private func renderArt(events: [(year: Int, text: String)]) -> NSImage? {
        let scheme = Self.colorSchemes.randomElement()!

        return ImageCanvas.render(width: width, height: height) {
            scheme.background.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: self.width, height: self.height)).fill()

            self.drawBorder(y: 80, color: scheme.accent)

            let titleFont = NSFont(name: "Helvetica", size: 40) ?? NSFont.systemFont(ofSize: 40)
            let textFont = NSFont(name: "Helvetica", size: 28) ?? NSFont.systemFont(ofSize: 28)
            let dateFont = NSFont(name: "Helvetica", size: 20) ?? NSFont.systemFont(ofSize: 20)

            drawCentered("On This Day in History", font: titleFont, color: scheme.accent, y: 100, canvasWidth: self.width)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM d"
            drawCentered(dateFormatter.string(from: Date()), font: dateFont, color: scheme.text, y: 180, canvasWidth: self.width)

            // "• Year  Text" per event, wrapped, capped to 12 lines total —
            // matches the original's textwrap behavior (which collapses the
            // year/text newline anyway since textwrap normalizes whitespace).
            var wrappedLines: [String] = []
            for event in events {
                wrappedLines.append(contentsOf: wrapText("• \(event.year)  \(event.text)", maxCharsPerLine: 65))
                wrappedLines.append("")
            }
            if wrappedLines.last == "" { wrappedLines.removeLast() }
            wrappedLines = Array(wrappedLines.prefix(12))

            let lineHeight: CGFloat = 45
            let totalTextHeight = CGFloat(wrappedLines.count) * lineHeight
            var currentY = (CGFloat(self.height) - totalTextHeight) / 2 + 50
            for line in wrappedLines {
                drawCentered(line, font: textFont, color: scheme.text, y: currentY, canvasWidth: self.width)
                currentY += lineHeight
            }

            self.drawBorder(y: CGFloat(self.height) - 120, color: scheme.accent)

            let year = Calendar.current.component(.year, from: Date())
            drawCentered("Historical Record - \(year)", font: dateFont, color: scheme.accent, y: CGFloat(self.height) - 70, canvasWidth: self.width)
        }
    }

    private func drawBorder(y: CGFloat, color: NSColor) {
        let border = NSBezierPath()
        border.lineWidth = 2
        for i in 0..<3 {
            border.move(to: NSPoint(x: 50, y: y + CGFloat(i)))
            border.line(to: NSPoint(x: CGFloat(width) - 50, y: y + CGFloat(i)))
        }
        color.setStroke()
        border.stroke()
    }
}
