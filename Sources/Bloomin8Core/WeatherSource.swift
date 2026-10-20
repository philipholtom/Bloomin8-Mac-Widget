import AppKit

/// Current weather conditions, rendered entirely from scratch (no downloaded
/// photo). Ported from weather_art_uploader.py, using Open-Meteo (free, no
/// API key). Location is configured in AppSettings — no default is set, so it
/// must be entered before this source will return useful results.
public struct WeatherSource: ContentSource {
    public let id = "weather"
    public let displayName = "Weather"
    public let galleryName = "Weather"

    private let width = 1200
    private let height = 1600

    private struct ColorScheme {
        let background: NSColor
        let text: NSColor
        let accent: NSColor
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let relativeHumidity2m: Double
            let apparentTemperature: Double
            let weatherCode: Int
            let windSpeed10m: Double

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case relativeHumidity2m = "relative_humidity_2m"
                case apparentTemperature = "apparent_temperature"
                case weatherCode = "weather_code"
                case windSpeed10m = "wind_speed_10m"
            }
        }
        let current: Current
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        let current = try await fetchWeather(latitude: settings.weatherLatitude, longitude: settings.weatherLongitude)
        guard let image = renderArt(current: current, locationName: settings.weatherLocationName),
              let jpeg = ImageCanvas.jpegData(image)
        else {
            throw ContentSourceError.message("Couldn't render weather image")
        }
        return jpeg
    }

    private func fetchWeather(latitude: Double, longitude: Double) async throws -> OpenMeteoResponse.Current {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("Weather API returned an error")
        }
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data).current
    }

    private func description(for code: Int) -> String {
        switch code {
        case 0: return "Clear Sky"
        case 1: return "Mainly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51: return "Light Drizzle"
        case 53: return "Moderate Drizzle"
        case 55: return "Dense Drizzle"
        case 61: return "Slight Rain"
        case 63: return "Moderate Rain"
        case 65: return "Heavy Rain"
        case 71: return "Slight Snow"
        case 73: return "Moderate Snow"
        case 75: return "Heavy Snow"
        case 80, 81: return "Rain Showers"
        case 82: return "Violent Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with Hail"
        default: return "Unknown"
        }
    }

    private func colorScheme(for code: Int) -> ColorScheme {
        switch code {
        case 0, 1:
            return ColorScheme(
                background: NSColor(red: 135/255, green: 206/255, blue: 235/255, alpha: 1),
                text: NSColor(red: 255/255, green: 200/255, blue: 50/255, alpha: 1),
                accent: NSColor(red: 255/255, green: 255/255, blue: 150/255, alpha: 1))
        case 2, 3:
            return ColorScheme(
                background: NSColor(red: 100/255, green: 100/255, blue: 120/255, alpha: 1),
                text: NSColor(red: 220/255, green: 220/255, blue: 230/255, alpha: 1),
                accent: NSColor(red: 180/255, green: 180/255, blue: 200/255, alpha: 1))
        case 45, 48:
            return ColorScheme(
                background: NSColor(red: 80/255, green: 85/255, blue: 90/255, alpha: 1),
                text: NSColor(red: 180/255, green: 180/255, blue: 190/255, alpha: 1),
                accent: NSColor(red: 140/255, green: 145/255, blue: 150/255, alpha: 1))
        case 51, 53, 55, 61, 63, 65, 80, 81, 82:
            return ColorScheme(
                background: NSColor(red: 50/255, green: 80/255, blue: 120/255, alpha: 1),
                text: NSColor(red: 150/255, green: 200/255, blue: 255/255, alpha: 1),
                accent: NSColor(red: 100/255, green: 150/255, blue: 200/255, alpha: 1))
        case 71, 73, 75, 85, 86:
            return ColorScheme(
                background: NSColor(red: 200/255, green: 220/255, blue: 240/255, alpha: 1),
                text: NSColor(red: 100/255, green: 120/255, blue: 150/255, alpha: 1),
                accent: NSColor(red: 150/255, green: 170/255, blue: 200/255, alpha: 1))
        case 95, 96, 99:
            return ColorScheme(
                background: NSColor(red: 40/255, green: 40/255, blue: 80/255, alpha: 1),
                text: NSColor(red: 200/255, green: 200/255, blue: 255/255, alpha: 1),
                accent: NSColor(red: 255/255, green: 200/255, blue: 100/255, alpha: 1))
        default:
            return ColorScheme(
                background: NSColor(red: 60/255, green: 100/255, blue: 140/255, alpha: 1),
                text: NSColor(red: 200/255, green: 220/255, blue: 240/255, alpha: 1),
                accent: NSColor(red: 150/255, green: 200/255, blue: 255/255, alpha: 1))
        }
    }

    private func drawWeatherIcon(x: CGFloat, y: CGFloat, code: Int, color: NSColor) {
        color.setStroke()
        switch code {
        case 0, 1: // Sun
            let path = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 80, height: 80))
            path.lineWidth = 3
            path.stroke()
        case 2, 3: // Cloud
            for rect in [
                NSRect(x: x, y: y + 20, width: 40, height: 40),
                NSRect(x: x + 30, y: y, width: 50, height: 50),
                NSRect(x: x + 60, y: y + 20, width: 40, height: 40)
            ] {
                let path = NSBezierPath(ovalIn: rect)
                path.lineWidth = 2
                path.stroke()
            }
        case 45, 48: // Fog
            for i in 0..<3 {
                let path = NSBezierPath(rect: NSRect(x: x, y: y + CGFloat(i) * 25 + 10, width: 80, height: 20))
                path.lineWidth = 2
                path.stroke()
            }
        case 61, 63, 65, 80, 81, 82: // Rain
            let cloud = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 40, height: 40))
            cloud.lineWidth = 2
            cloud.stroke()
            for dx in [CGFloat(10), 25, 40] {
                let drop = NSBezierPath()
                drop.lineWidth = 2
                drop.move(to: NSPoint(x: x + dx, y: y + 45))
                drop.line(to: NSPoint(x: x + dx + 5, y: y + 70))
                drop.stroke()
            }
        case 71, 73, 75, 85, 86: // Snow
            for i in 0..<5 {
                let flake = NSBezierPath()
                flake.lineWidth = 2
                let lineX = x + 10 + CGFloat(i) * 15
                flake.move(to: NSPoint(x: lineX, y: y))
                flake.line(to: NSPoint(x: lineX, y: y + 80))
                flake.stroke()
            }
        default:
            break // Thunderstorm has no icon in the original either.
        }
    }

    private func renderArt(current: OpenMeteoResponse.Current, locationName: String) -> NSImage? {
        let scheme = colorScheme(for: current.weatherCode)
        let desc = description(for: current.weatherCode)

        return ImageCanvas.render(width: width, height: height) {
            scheme.background.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: self.width, height: self.height)).fill()

            let titleFont = NSFont(name: "Helvetica", size: 44) ?? NSFont.systemFont(ofSize: 44)
            let largeFont = NSFont(name: "Helvetica", size: 72) ?? NSFont.systemFont(ofSize: 72)
            let mediumFont = NSFont(name: "Helvetica", size: 32) ?? NSFont.systemFont(ofSize: 32)
            let smallFont = NSFont(name: "Helvetica", size: 24) ?? NSFont.systemFont(ofSize: 24)

            drawCentered(locationName, font: titleFont, color: scheme.accent, y: 100, canvasWidth: self.width)
            drawCentered("\(Int(current.temperature2m))°C", font: largeFont, color: scheme.text, y: 220, canvasWidth: self.width)
            drawCentered(desc, font: mediumFont, color: scheme.text, y: 350, canvasWidth: self.width)

            self.drawWeatherIcon(x: CGFloat(self.width) / 2 - 40, y: 450, code: current.weatherCode, color: scheme.accent)

            var y: CGFloat = 650
            let lineHeight: CGFloat = 70
            drawCentered("Feels like \(Int(current.apparentTemperature))°C", font: smallFont, color: scheme.text, y: y, canvasWidth: self.width)
            y += lineHeight
            drawCentered("Humidity: \(Int(current.relativeHumidity2m))%", font: smallFont, color: scheme.text, y: y, canvasWidth: self.width)
            y += lineHeight
            drawCentered("Wind: \(Int(current.windSpeed10m)) km/h", font: smallFont, color: scheme.text, y: y, canvasWidth: self.width)

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            drawCentered(timeFormatter.string(from: Date()), font: smallFont, color: scheme.accent, y: CGFloat(self.height) - 80, canvasWidth: self.width)
        }
    }
}
