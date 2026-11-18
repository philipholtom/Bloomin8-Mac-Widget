import AppKit

/// One card for the start of the day: the date, the forecast, the nearest
/// countdown and today's calendar events. It reuses the Agenda settings
/// (calendars to leave out, forecast on/off) and the Countdown events, so
/// there is nothing extra to set up. A "today" source: put it on a daily
/// schedule and it's current every morning.
public struct MorningDashboardSource: TodayContentSource {
    public init() {}

    public static let sourceID = "morning-dashboard"
    public let id = MorningDashboardSource.sourceID
    public let displayName = "Morning dashboard"
    public let galleryName = "Morning"
    public let todayButtonTitle = "Today's dashboard"

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
        let options = AgendaOptions.stored()
        let now = Date()
        // Without calendar access the card still shows the date, weather and countdown.
        var entries: [AgendaSource.Entry]?
        if await AgendaCalendars.requestAccess() {
            entries = AgendaCalendars.entries(on: now, excluding: options.excludedCalendarIDs)
        }
        var weather: String?
        if options.showWeather, settings.weatherLatitude != 0 || settings.weatherLongitude != 0 {
            weather = try? await AgendaSource.forecastLine(latitude: settings.weatherLatitude, longitude: settings.weatherLongitude)
        }
        let countdown = CountdownSource.upcoming(CountdownOptions.stored().events, now: now).first
        guard let image = Self.render(day: now, weather: weather, countdown: countdown, entries: entries,
                                      width: settings.renderWidth, height: settings.renderHeight),
              let jpeg = ImageCanvas.jpegData(image)
        else { throw ContentSourceError.message("Couldn't draw the dashboard.") }

        var card = MuseumCard()
        card.title = "Good morning"
        let display = DateFormatter()
        display.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        card.date = display.string(from: now)
        card.notes = [weather, entries.map { $0.isEmpty ? "Nothing scheduled." : "\($0.count) event\($0.count == 1 ? "" : "s") today." }]
            .compactMap { $0 }.joined(separator: " ")
        return GeneratedContent(data: jpeg, card: card.normalized())
    }

    // MARK: - Drawing

    private static let ink = NSColor.black
    private static let soft = NSColor(white: 0.35, alpha: 1)
    private static let accent = NSColor(red: 0.72, green: 0.1, blue: 0.08, alpha: 1)

    /// Draws the card. Free of EventKit and the network so it can be tried with made-up data.
    /// `entries` is nil when the calendar isn't available.
    public static func render(day: Date, weather: String?, countdown: CountdownSource.Upcoming?,
                              entries: [AgendaSource.Entry]?, width: Int, height: Int) -> NSImage? {
        ImageCanvas.render(width: width, height: height) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let canvas = CGSize(width: width, height: height)
            if width > height {
                drawLandscape(day: day, weather: weather, countdown: countdown, entries: entries, canvas: canvas)
            } else {
                drawPortrait(day: day, weather: weather, countdown: countdown, entries: entries, canvas: canvas)
            }
        }
    }

    private static func drawPortrait(day: Date, weather: String?, countdown: CountdownSource.Upcoming?,
                                     entries: [AgendaSource.Entry]?, canvas: CGSize) {
        let margin: CGFloat = 80
        let inner = canvas.width - margin * 2
        var y = header(day: day, weather: weather, x: margin, y: 90, width: inner, weekdaySize: 110, dateSize: 64, weatherSize: 40)
        y += 24
        rule(x: margin, y: y, width: inner)
        y += 36
        if let countdown {
            y = countdownLine(countdown, x: margin, y: y, width: inner, size: 46)
            y += 30
            rule(x: margin, y: y, width: inner)
            y += 36
        }
        agenda(entries, x: margin, top: y, bottom: canvas.height - 70, width: inner, large: true)
    }

    private static func drawLandscape(day: Date, weather: String?, countdown: CountdownSource.Upcoming?,
                                      entries: [AgendaSource.Entry]?, canvas: CGSize) {
        let margin = canvas.height * 0.09
        let leftWidth = canvas.width * 0.38
        var y = header(day: day, weather: weather, x: margin, y: margin, width: leftWidth - margin, weekdaySize: 78, dateSize: 48, weatherSize: 30)
        if let countdown {
            y += 30
            rule(x: margin, y: y, width: leftWidth - margin)
            y += 26
            _ = countdownLine(countdown, x: margin, y: y, width: leftWidth - margin, size: 34)
        }
        let rightX = leftWidth + margin
        NSColor(white: 0.75, alpha: 1).setFill()
        NSRect(x: leftWidth + margin / 2, y: margin, width: 3, height: canvas.height - margin * 2).fill()
        agenda(entries, x: rightX, top: margin, bottom: canvas.height - margin / 2, width: canvas.width - rightX - margin, large: false)
    }

    /// Weekday, date and forecast; returns the y below them.
    private static func header(day: Date, weather: String?, x: CGFloat, y: CGFloat, width: CGFloat,
                               weekdaySize: CGFloat, dateSize: CGFloat, weatherSize: CGFloat) -> CGFloat {
        let weekday = DateFormatter()
        weekday.dateFormat = "EEEE"
        let date = DateFormatter()
        date.setLocalizedDateFormatFromTemplate("d MMMM")
        var y = y
        draw(truncated(weekday.string(from: day), font: font(weekdaySize, bold: true), width: width), font: font(weekdaySize, bold: true), color: ink, x: x, y: y)
        y += weekdaySize * 1.18
        draw(date.string(from: day), font: font(dateSize), color: accent, x: x, y: y)
        y += dateSize * 1.3
        if let weather, !weather.isEmpty {
            draw(truncated(weather, font: font(weatherSize), width: width), font: font(weatherSize), color: soft, x: x, y: y)
            y += weatherSize * 1.4
        }
        return y
    }

    private static func countdownLine(_ item: CountdownSource.Upcoming, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat) -> CGFloat {
        let when = item.days == 0 ? "Today" : (item.days == 1 ? "Tomorrow" : "\(item.days) days")
        draw(when, font: font(size, bold: true), color: accent, x: x, y: y)
        let whenWidth = (when as NSString).size(withAttributes: [.font: font(size, bold: true)]).width + size * 0.5
        let name = truncated(item.event.name, font: font(size), width: max(40, width - whenWidth))
        draw(name, font: font(size), color: ink, x: x + whenWidth, y: y)
        return y + size * 1.3
    }

    private static func agenda(_ entries: [AgendaSource.Entry]?, x: CGFloat, top: CGFloat, bottom: CGFloat, width: CGFloat, large: Bool) {
        var y = top
        draw("TODAY", font: font(large ? 30 : 26, bold: true), color: accent, x: x, y: y)
        y += large ? 52 : 46
        guard let entries else {
            draw("Calendar not available", font: font(large ? 40 : 32), color: soft, x: x, y: y)
            return
        }
        guard !entries.isEmpty else {
            draw("Nothing scheduled", font: font(large ? 50 : 40), color: soft, x: x, y: y)
            return
        }
        let titleFont = font(large ? 50 : 38, bold: true)
        let timeFont = font(large ? 40 : 30)
        let detailFont = font(large ? 32 : 26)
        let timeWidth: CGFloat = large ? 220 : 170
        let titleWidth = width - timeWidth
        let rowHeight: CGFloat = large ? 64 : 50
        let detailHeight: CGFloat = large ? 44 : 36
        for (index, entry) in entries.enumerated() {
            let needed = rowHeight + (entry.detail.isEmpty ? 0 : detailHeight) + 18
            let reserve: CGFloat = index == entries.count - 1 ? 0 : 50
            if y + needed + reserve > bottom {
                draw("+ \(entries.count - index) more", font: font(large ? 36 : 28), color: soft, x: x + timeWidth, y: y)
                return
            }
            draw(entry.time, font: timeFont, color: soft, x: x, y: y + (large ? 8 : 5))
            draw(truncated(entry.title, font: titleFont, width: titleWidth), font: titleFont, color: ink, x: x + timeWidth, y: y)
            y += rowHeight
            if !entry.detail.isEmpty {
                draw(truncated(entry.detail, font: detailFont, width: titleWidth), font: detailFont, color: soft, x: x + timeWidth, y: y)
                y += detailHeight
            }
            y += 18
        }
    }

    // MARK: - Text helpers

    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    }

    private static func rule(x: CGFloat, y: CGFloat, width: CGFloat) {
        NSColor(white: 0.75, alpha: 1).setFill()
        NSRect(x: x, y: y, width: width, height: 3).fill()
    }

    private static func truncated(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var result = text.replacingOccurrences(of: "\n", with: " ")
        guard (result as NSString).size(withAttributes: attrs).width > width else { return result }
        while result.count > 1, ((result + "…") as NSString).size(withAttributes: attrs).width > width {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Left-aligned text hanging from a top-left origin (the canvas is flipped, so counter-flip the text).
    private static func draw(_ text: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = text as NSString
        let size = string.size(withAttributes: attrs)
        context.saveGState()
        context.translateBy(x: x, y: y + size.height)
        context.scaleBy(x: 1, y: -1)
        string.draw(at: .zero, withAttributes: attrs)
        context.restoreGState()
    }
}
