import AppKit
import EventKit

/// What the Agenda card shows. Stored once for both products.
public struct AgendaOptions: Codable, Equatable {
    public var includeTomorrow = true
    /// A one-line forecast under the date, when a weather location is set.
    public var showWeather = true
    /// Calendars left off the card (by EventKit identifier). Empty = all shown.
    public var excludedCalendarIDs: Set<String> = []

    public init() {}

    private static let defaultsKey = "agendaOptions"

    public static func stored() -> AgendaOptions {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AgendaOptions.self, from: data) else { return AgendaOptions() }
        return decoded
    }

    public static func store(_ options: AgendaOptions, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: defaultsKey) }
    }
}

/// Calendar access for the Agenda card. Each app (Bloomin8 Mac, the widget)
/// has to be allowed separately — macOS grants calendar access per app.
public enum AgendaCalendars {
    private static let store = EKEventStore()

    public static var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    /// True if this app has never asked — asking now shows the macOS prompt.
    public static var canAsk: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    /// Shows the macOS permission prompt the first time; afterwards just reports the answer.
    public static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        guard canAsk else { return false }
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return (try? await store.requestAccess(to: .event)) ?? false
    }

    public struct CalendarInfo: Identifiable, Hashable {
        public let id: String
        public let title: String
        public let source: String
    }

    public static func calendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// The events on the calendar day containing `day`, minus excluded
    /// calendars and anything declined, all-day ones first.
    static func entries(on day: Date, excluding excluded: Set<String>) -> [AgendaSource.Entry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let chosen = store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: chosen))
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        return events
            .filter { event in
                let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
                return !declined && event.status != .canceled
            }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { event in
                // An event that began before today reads as "all day" too.
                let allDay = event.isAllDay || (event.startDate <= start && event.endDate >= end)
                return AgendaSource.Entry(
                    time: allDay ? "All day" : time.string(from: max(event.startDate, start)),
                    title: event.title ?? "(No title)",
                    detail: (event.location ?? "").components(separatedBy: .newlines).first ?? ""
                )
            }
    }
}

/// A card of today's calendar events (and tomorrow's), with the date and a
/// one-line forecast: black on white, which is what the e-ink panel shows
/// most crisply. Reads the Mac's calendars through EventKit.
public struct AgendaSource: ContentSource {
    public init() {}

    public static let sourceID = "agenda"
    public let id = AgendaSource.sourceID
    public let displayName = "Agenda"
    public let galleryName = "Agenda"

    public struct Entry: Equatable {
        public var time: String
        public var title: String
        public var detail: String
        public init(time: String, title: String, detail: String = "") {
            self.time = time
            self.title = title
            self.detail = detail
        }
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        try await generateImageAndCard(settings: settings).data
    }

    public func generateImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        guard await AgendaCalendars.requestAccess() else {
            throw ContentSourceError.message("Calendar access is off. Allow it for this app in System Settings → Privacy & Security → Calendars.")
        }
        let options = AgendaOptions.stored()
        let now = Date()
        let today = AgendaCalendars.entries(on: now, excluding: options.excludedCalendarIDs)
        var tomorrow: [Entry]?
        if options.includeTomorrow, let next = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            tomorrow = AgendaCalendars.entries(on: next, excluding: options.excludedCalendarIDs)
        }
        var weather: String?
        if options.showWeather, settings.weatherLatitude != 0 || settings.weatherLongitude != 0 {
            weather = try? await Self.forecastLine(latitude: settings.weatherLatitude, longitude: settings.weatherLongitude)
        }
        guard let image = Self.render(day: now, today: today, tomorrow: tomorrow, weather: weather),
              let jpeg = ImageCanvas.jpegData(image)
        else { throw ContentSourceError.message("Couldn't draw the agenda.") }

        var card = MuseumCard()
        card.title = "Today's agenda"
        let display = DateFormatter()
        display.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        card.date = display.string(from: now)
        card.notes = today.isEmpty ? "Nothing scheduled." : "\(today.count) event\(today.count == 1 ? "" : "s") today."
        return GeneratedContent(data: jpeg, card: card.normalized())
    }

    // MARK: - Weather line

    private struct Forecast: Decodable {
        struct Daily: Decodable {
            let weatherCode: [Int]
            let max: [Double]
            let min: [Double]
            enum CodingKeys: String, CodingKey {
                case weatherCode = "weather_code"
                case max = "temperature_2m_max"
                case min = "temperature_2m_min"
            }
        }
        let daily: Daily
    }

    /// "Light rain · 12° / 6°" for today, from Open-Meteo (free, no key).
    static func forecastLine(latitude: Double, longitude: Double) async throws -> String? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        let daily = try JSONDecoder().decode(Forecast.self, from: data).daily
        guard let code = daily.weatherCode.first, let high = daily.max.first, let low = daily.min.first else { return nil }
        return "\(weatherWord(code)) · \(Int(high.rounded()))° / \(Int(low.rounded()))°"
    }

    public static func weatherWord(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61: return "Light rain"
        case 63, 66: return "Rain"
        case 65, 67: return "Heavy rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95, 96, 99: return "Thunderstorms"
        default: return "Weather"
        }
    }

    // MARK: - Drawing

    private static let width = 1200
    private static let height = 1600
    private static let margin: CGFloat = 80
    private static let ink = NSColor.black
    private static let soft = NSColor(white: 0.35, alpha: 1)
    private static let accent = NSColor(red: 0.72, green: 0.1, blue: 0.08, alpha: 1)

    /// Draws the card. Public and free of EventKit so it can be exercised
    /// with made-up entries.
    public static func render(day: Date, today: [Entry], tomorrow: [Entry]?, weather: String?) -> NSImage? {
        ImageCanvas.render(width: width, height: height) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            let weekday = DateFormatter()
            weekday.dateFormat = "EEEE"
            let date = DateFormatter()
            date.setLocalizedDateFormatFromTemplate("d MMMM")

            var y: CGFloat = 90
            draw(weekday.string(from: day), font: font(110, bold: true), color: ink, x: margin, y: y)
            y += 130
            draw(date.string(from: day), font: font(64), color: accent, x: margin, y: y)
            y += 84
            if let weather, !weather.isEmpty {
                draw(weather, font: font(40), color: soft, x: margin, y: y)
                y += 56
            }
            y += 24
            rule(at: y)
            y += 40

            // Tomorrow gets what's left once today has had its share.
            let bottom = CGFloat(height) - 70
            let tomorrowReserve: CGFloat = (tomorrow == nil) ? 0 : 260
            y = section(nil, entries: today, emptyText: "Nothing scheduled today", from: y, to: bottom - tomorrowReserve, large: true)
            if let tomorrow {
                y += 30
                rule(at: y)
                y += 34
                _ = section("Tomorrow", entries: tomorrow, emptyText: "Nothing scheduled", from: y, to: bottom, large: false)
            }
        }
    }

    /// Draws as many entries as fit between `top` and `limit`, with "+N more"
    /// for the rest. Returns the y below the last line drawn.
    private static func section(_ heading: String?, entries: [Entry], emptyText: String, from top: CGFloat, to limit: CGFloat, large: Bool) -> CGFloat {
        var y = top
        if let heading {
            draw(heading.uppercased(), font: font(30, bold: true), color: accent, x: margin, y: y)
            y += 52
        }
        let titleFont = font(large ? 50 : 40, bold: true)
        let timeFont = font(large ? 40 : 34)
        let detailFont = font(large ? 32 : 28)
        let timeWidth: CGFloat = large ? 220 : 190
        let titleX = margin + timeWidth
        let titleWidth = CGFloat(width) - margin - titleX
        let rowHeight: CGFloat = large ? 64 : 52
        let detailHeight: CGFloat = large ? 44 : 38

        guard !entries.isEmpty else {
            draw(emptyText, font: font(large ? 46 : 38), color: soft, x: margin, y: y)
            return y + rowHeight
        }
        for (index, entry) in entries.enumerated() {
            let needed = rowHeight + (entry.detail.isEmpty ? 0 : detailHeight) + 18
            // Keep room for the "+N more" line unless this is the last entry.
            let reserve: CGFloat = index == entries.count - 1 ? 0 : 50
            if y + needed + reserve > limit {
                let left = entries.count - index
                draw("+ \(left) more", font: font(large ? 36 : 30), color: soft, x: titleX, y: y)
                return y + 50
            }
            draw(entry.time, font: timeFont, color: soft, x: margin, y: y + (large ? 8 : 5))
            draw(truncated(entry.title, font: titleFont, width: titleWidth), font: titleFont, color: ink, x: titleX, y: y)
            y += rowHeight
            if !entry.detail.isEmpty {
                draw(truncated(entry.detail, font: detailFont, width: titleWidth), font: detailFont, color: soft, x: titleX, y: y)
                y += detailHeight
            }
            y += 18
        }
        return y
    }

    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    }

    private static func rule(at y: CGFloat) {
        NSColor(white: 0.75, alpha: 1).setFill()
        NSRect(x: margin, y: y, width: CGFloat(width) - margin * 2, height: 3).fill()
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

    /// Left-aligned text at a top-left origin, counter-flipped like `drawCentered`.
    private static func draw(_ text: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let nsText = text as NSString
        guard let context = NSGraphicsContext.current?.cgContext else {
            nsText.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            return
        }
        // After the local flip the text hangs below the origin, so start a line-height down.
        let lineHeight = nsText.size(withAttributes: attrs).height
        context.saveGState()
        context.translateBy(x: x, y: y + lineHeight)
        context.scaleBy(x: 1, y: -1)
        nsText.draw(at: .zero, withAttributes: attrs)
        context.restoreGState()
    }
}
