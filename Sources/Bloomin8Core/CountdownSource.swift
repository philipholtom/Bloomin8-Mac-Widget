import AppKit

/// One date to count down to.
public struct CountdownEvent: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Any moment on the day; only the calendar day counts.
    public var date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

/// The events the Countdown card counts down to. Stored once for both products.
public struct CountdownOptions: Codable, Equatable {
    public var events: [CountdownEvent] = []

    public init() {}

    private static let defaultsKey = "countdownOptions"

    public static func stored() -> CountdownOptions {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(CountdownOptions.self, from: data) else { return CountdownOptions() }
        return decoded
    }

    public static func store(_ options: CountdownOptions, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: defaultsKey) }
    }
}

/// A card counting down the days to your nearest event, with the next couple
/// below it. It's a "today" source: put it on a daily schedule (Settings →
/// Automation → Scheduled Content, "Use today's picture") and the number is
/// right every morning, one file a day replacing yesterday's.
public struct CountdownSource: TodayContentSource {
    public init() {}

    public let id = "countdown"
    public let displayName = "Countdown"
    public let galleryName = "Countdown"
    public let todayButtonTitle = "Today's countdown"

    public func generateImage(settings: AppSettings) async throws -> Data {
        try await generateImageAndCard(settings: settings).data
    }

    public func generateTodayImage(settings: AppSettings) async throws -> Data {
        try await generateImageAndCard(settings: settings).data
    }

    public func generateTodayImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        try await generateImageAndCard(settings: settings)
    }

    public func generateImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        let upcoming = Self.upcoming(CountdownOptions.stored().events, now: Date())
        guard let next = upcoming.first else {
            throw ContentSourceError.message("No upcoming events to count down to. Add one in Settings → Content → Countdown.")
        }
        guard let image = Self.render(upcoming, width: settings.renderWidth, height: settings.renderHeight),
              let jpeg = ImageCanvas.jpegData(image)
        else { throw ContentSourceError.message("Couldn't draw the countdown.") }

        var card = MuseumCard()
        card.title = next.event.name
        let display = DateFormatter()
        display.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        card.date = display.string(from: next.event.date)
        card.notes = Self.phrase(days: next.days)
        return GeneratedContent(data: jpeg, card: card.normalized())
    }

    // MARK: - Working out the days

    public struct Upcoming: Equatable {
        public let event: CountdownEvent
        public let days: Int
    }

    /// Events from today onwards, soonest first, each with its whole days to go.
    public static func upcoming(_ events: [CountdownEvent], now: Date) -> [Upcoming] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return events
            .compactMap { event -> Upcoming? in
                let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: event.date)).day ?? -1
                return days >= 0 ? Upcoming(event: event, days: days) : nil
            }
            .filter { !$0.event.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.days, $0.event.name) < ($1.days, $1.event.name) }
    }

    /// "Today!", "Tomorrow", "12 days to go".
    public static func phrase(days: Int) -> String {
        switch days {
        case 0: return "Today!"
        case 1: return "Tomorrow"
        default: return "\(days) days to go"
        }
    }

    // MARK: - Drawing

    private static let ink = NSColor.black
    private static let soft = NSColor(white: 0.35, alpha: 1)
    private static let accent = NSColor(red: 0.72, green: 0.1, blue: 0.08, alpha: 1)

    /// Draws the card. Public and free of settings so it can be tried with fixed dates.
    public static func render(_ upcoming: [Upcoming], width: Int, height: Int) -> NSImage? {
        guard let next = upcoming.first else { return nil }
        return ImageCanvas.render(width: width, height: height) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let canvas = CGSize(width: width, height: height)
            if width > height { drawLandscape(upcoming, next: next, canvas: canvas) } else { drawPortrait(upcoming, next: next, canvas: canvas) }
        }
    }

    private static func drawPortrait(_ upcoming: [Upcoming], next: Upcoming, canvas: CGSize) {
        let margin = canvas.width * 0.08
        let centerX = canvas.width / 2
        var y = margin
        line("COUNTDOWN", size: 36, bold: true, color: accent, centerX: centerX, y: &y)
        y += 20
        // The name, wrapped and shrunk to fit two lines at most.
        let name = fitted(next.event.name, maxWidth: canvas.width - margin * 2, maxLines: 2, upper: 120)
        for text in name.lines { drawLine(text, font: name.font, color: ink, centerX: centerX, top: y); y += name.lineHeight }
        y += 40

        let big = bigNumber(next.days)
        let numberSize: CGFloat = next.days == 0 ? 300 : (big.count > 3 ? 380 : 520)
        let numberFont = font(numberSize, bold: true)
        let numberHeight = numberFont.pointSize * 1.1
        drawLine(big, font: numberFont, color: ink, centerX: centerX, top: y)
        y += numberHeight
        if next.days >= 2 { line("days to go", size: 70, bold: false, color: soft, centerX: centerX, y: &y) }
        else if next.days == 1 { line("day to go", size: 70, bold: false, color: soft, centerX: centerX, y: &y) }
        y += 16
        line(longDate(next.event.date), size: 46, bold: false, color: soft, centerX: centerX, y: &y)

        let rest = Array(upcoming.dropFirst().prefix(2))
        if !rest.isEmpty {
            let bottom = canvas.height - margin
            var below = bottom - CGFloat(rest.count) * 66 - 30
            NSColor(white: 0.75, alpha: 1).setFill()
            NSRect(x: margin, y: below, width: canvas.width - margin * 2, height: 3).fill()
            below += 30
            for item in rest {
                let text = fittedLine("\(item.event.name)  ·  \(phraseShort(item.days))", size: 44, maxWidth: canvas.width - margin * 2)
                drawLine(text.text, font: text.font, color: soft, centerX: centerX, top: below)
                below += 66
            }
        }
    }

    private static func drawLandscape(_ upcoming: [Upcoming], next: Upcoming, canvas: CGSize) {
        let margin = canvas.height * 0.09
        let leftWidth = canvas.width * 0.42
        // Number on the left.
        let big = bigNumber(next.days)
        let numberSize: CGFloat = next.days == 0 ? 220 : (big.count > 3 ? 280 : 380)
        let numberFont = font(numberSize, bold: true)
        let labelHeight: CGFloat = next.days >= 1 ? 80 : 0
        let numberTop = (canvas.height - numberFont.pointSize * 1.1 - labelHeight) / 2
        drawLine(big, font: numberFont, color: ink, centerX: leftWidth / 2 + margin / 2, top: numberTop)
        if next.days >= 1 {
            drawLine(next.days == 1 ? "day to go" : "days to go", font: font(56), color: soft, centerX: leftWidth / 2 + margin / 2, top: numberTop + numberFont.pointSize * 1.1)
        }
        // Words on the right.
        let rightX = leftWidth + margin
        let rightWidth = canvas.width - rightX - margin
        let centerX = rightX + rightWidth / 2
        var y = margin
        line("COUNTDOWN", size: 30, bold: true, color: accent, centerX: centerX, y: &y)
        y += 14
        let name = fitted(next.event.name, maxWidth: rightWidth, maxLines: 3, upper: 96)
        for text in name.lines { drawLine(text, font: name.font, color: ink, centerX: centerX, top: y); y += name.lineHeight }
        y += 20
        let date = fittedLine(longDate(next.event.date), size: 40, maxWidth: rightWidth)
        drawLine(date.text, font: date.font, color: soft, centerX: centerX, top: y)
        var below = canvas.height - margin - 150
        for item in upcoming.dropFirst().prefix(2) {
            let text = fittedLine("\(item.event.name)  ·  \(phraseShort(item.days))", size: 34, maxWidth: rightWidth)
            drawLine(text.text, font: text.font, color: soft, centerX: centerX, top: below)
            below += 56
        }
    }

    private static func bigNumber(_ days: Int) -> String { days == 0 ? "Today!" : "\(days)" }

    private static func phraseShort(_ days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "\(days) days"
        }
    }

    private static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        return formatter.string(from: date)
    }

    // MARK: - Text helpers

    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    }

    /// The biggest size (down from `upper`) where `text` wraps to at most `maxLines` lines.
    private static func fitted(_ text: String, maxWidth: CGFloat, maxLines: Int, upper: CGFloat) -> (font: NSFont, lines: [String], lineHeight: CGFloat) {
        var size = upper
        while size > 24 {
            let f = font(size, bold: true)
            let lines = wrapTextToWidth(text, font: f, maxWidth: maxWidth)
            if lines.count <= maxLines { return (f, lines, size * 1.2) }
            size -= 4
        }
        let f = font(24, bold: true)
        return (f, Array(wrapTextToWidth(text, font: f, maxWidth: maxWidth).prefix(maxLines)), 29)
    }

    private static func fittedLine(_ text: String, size: CGFloat, maxWidth: CGFloat) -> (text: String, font: NSFont) {
        var current = size
        var f = font(current)
        while current > 20, (text as NSString).size(withAttributes: [.font: f]).width > maxWidth {
            current -= 2
            f = font(current)
        }
        return (text, f)
    }

    /// One centred line at `y`, which then moves down by the line's height.
    private static func line(_ text: String, size: CGFloat, bold: Bool, color: NSColor, centerX: CGFloat, y: inout CGFloat) {
        let f = font(size, bold: bold)
        drawLine(text, font: f, color: color, centerX: centerX, top: y)
        y += size * 1.3
    }

    private static func drawLine(_ text: String, font: NSFont, color: NSColor, centerX: CGFloat, top: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = text as NSString
        let size = string.size(withAttributes: attrs)
        context.saveGState()
        context.translateBy(x: centerX - size.width / 2, y: top + size.height)
        context.scaleBy(x: 1, y: -1)
        string.draw(at: .zero, withAttributes: attrs)
        context.restoreGState()
    }
}
