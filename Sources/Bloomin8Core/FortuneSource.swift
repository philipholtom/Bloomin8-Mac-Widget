import AppKit

/// A random quote rendered as artistic text on a colored background. Tries
/// the Unix `fortune` command first (if installed via Homebrew, matching
/// fortune_art_uploader.py), falling back to a bundled quote list so this
/// works out of the box without any extra install.
public struct FortuneSource: ContentSource {
    public init() {}

    public let id = "fortune"
    public let displayName = "Fortune"
    public let galleryName = "Fortune"

    private let width = 1200
    private let height = 1600

    private struct ColorScheme {
        let background: NSColor
        let text: NSColor
        let accent: NSColor
    }

    private static let colorSchemes: [ColorScheme] = [
        ColorScheme(background: NSColor(red: 25/255, green: 50/255, blue: 100/255, alpha: 1),
                    text: NSColor(red: 220/255, green: 240/255, blue: 255/255, alpha: 1),
                    accent: NSColor(red: 100/255, green: 200/255, blue: 255/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 80/255, green: 30/255, blue: 50/255, alpha: 1),
                    text: NSColor(red: 255/255, green: 200/255, blue: 100/255, alpha: 1),
                    accent: NSColor(red: 255/255, green: 100/255, blue: 50/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 20/255, green: 60/255, blue: 40/255, alpha: 1),
                    text: NSColor(red: 180/255, green: 220/255, blue: 180/255, alpha: 1),
                    accent: NSColor(red: 100/255, green: 200/255, blue: 120/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 120/255, green: 80/255, blue: 40/255, alpha: 1),
                    text: NSColor(red: 255/255, green: 240/255, blue: 200/255, alpha: 1),
                    accent: NSColor(red: 255/255, green: 160/255, blue: 80/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 10/255, green: 10/255, blue: 30/255, alpha: 1),
                    text: NSColor(red: 200/255, green: 200/255, blue: 255/255, alpha: 1),
                    accent: NSColor(red: 150/255, green: 100/255, blue: 255/255, alpha: 1)),
    ]

    private static let bundledQuotes: [String] = [
        "The best way to predict the future is to invent it.",
        "A journey of a thousand miles begins with a single step.",
        "Simplicity is the ultimate sophistication.",
        "Fortune favors the bold.",
        "The only way to do great work is to love what you do.",
        "What you seek is seeking you.",
        "Small deeds done are better than great deeds planned.",
        "The obstacle is the way.",
        "Patience is bitter, but its fruit is sweet.",
        "He who has a why to live can bear almost any how.",
        "The unexamined life is not worth living.",
        "Out of clutter, find simplicity.",
        "In the middle of difficulty lies opportunity.",
        "Do not wait for the perfect moment, take the moment and make it perfect.",
        "A smooth sea never made a skilled sailor.",
        "Turn your wounds into wisdom.",
        "Whatever you are, be a good one.",
        "The best time to plant a tree was twenty years ago. The second best time is now.",
        "You miss 100% of the shots you don't take.",
        "Fall seven times, stand up eight.",
        "Not all those who wander are lost.",
        "Every strike brings me closer to the next home run.",
        "Do what you can, with what you have, where you are.",
        "The mind is everything. What you think, you become.",
        "It always seems impossible until it's done.",
        "Well begun is half done.",
        "Great things are done by a series of small things brought together.",
        "The secret of getting ahead is getting started.",
        "Quality is not an act, it is a habit.",
        "Perseverance is not a long race; it is many short races one after another.",
        "You are never too old to set another goal or dream a new dream.",
        "Believe you can and you're halfway there.",
        "Act as if what you do makes a difference. It does.",
        "Success is the sum of small efforts repeated day in and day out.",
        "Nothing is impossible, the word itself says I'm possible.",
        "Dream big and dare to fail.",
        "The future belongs to those who believe in the beauty of their dreams.",
        "Keep your face always toward the sunshine, and shadows will fall behind you.",
        "Everything you've ever wanted is on the other side of fear.",
        "Life is 10% what happens to us and 90% how we react to it.",
        "The harder I work, the luckier I get.",
        "Don't watch the clock; do what it does. Keep going.",
        "Opportunities don't happen, you create them.",
        "Success is not final, failure is not fatal: it is the courage to continue that counts.",
        "A river cuts through rock, not because of its power, but because of its persistence.",
        "The best view comes after the hardest climb.",
        "Little by little, one travels far.",
        "Calm seas never made a good sailor.",
        "Even the darkest night will end and the sun will rise.",
        "Good things come to those who hustle.",
    ]

    public func generateImage(settings: AppSettings) async throws -> Data {
        let quote = await fetchFortune()
        guard let image = renderArt(quote: quote), let jpeg = ImageCanvas.jpegData(image) else {
            throw ContentSourceError.message("Couldn't render fortune image")
        }
        return jpeg
    }

    private func fetchFortune() async -> String {
        if let text = try? await runSystemFortune(), !text.isEmpty {
            return text
        }
        return Self.bundledQuotes.randomElement() ?? "Good things come to those who wait."
    }

    /// `fortune` isn't bundled with macOS — this only fires if the user has
    /// installed it themselves (e.g. `brew install fortune`), otherwise we
    /// silently fall back to the bundled list.
    private func runSystemFortune() async throws -> String? {
        let candidatePaths = ["/opt/homebrew/bin/fortune", "/usr/local/bin/fortune", "/usr/games/fortune"]
        guard let path = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: proc.terminationStatus == 0 ? text : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func renderArt(quote: String) -> NSImage? {
        let scheme = Self.colorSchemes.randomElement()!

        // Pick the largest font that fits the available width/height, then
        // lay out the whole border+text+date block and center *that block*
        // vertically on the canvas — rather than anchoring the top border and
        // date at fixed positions, which left a large dead zone between the
        // bottom border and the date whenever a short quote didn't need the
        // full height. Centering the block means a short quote's extra space
        // gets distributed evenly above and below instead of dumped at the
        // bottom, so the design reads as filling the frame either way.
        let sideMargin: CGFloat = 100
        let maxTextWidth = CGFloat(width) - 2 * sideMargin
        let borderToTextGap: CGFloat = 60
        let textToBorderGap: CGFloat = 40
        let borderToDateGap: CGFloat = 60
        let dateFont = NSFont(name: "Helvetica", size: 20) ?? NSFont.systemFont(ofSize: 20)
        let dateHeight = dateFont.pointSize
        let minTopMargin: CGFloat = 100
        let bottomSafety: CGFloat = 60

        let maxTextHeight = CGFloat(height) - 2 * minTopMargin - borderToTextGap - textToBorderGap - borderToDateGap - dateHeight - bottomSafety

        let fitted = fittingFontSize(
            for: quote,
            fontName: "Helvetica",
            range: 28...220,
            maxWidth: maxTextWidth,
            maxHeight: maxTextHeight
        )

        let textHeight = CGFloat(fitted.lines.count) * fitted.lineHeight
        let blockHeight = borderToTextGap + textHeight + textToBorderGap + borderToDateGap + dateHeight
        let topBorderY = max(minTopMargin, (CGFloat(height) - blockHeight) / 2)

        return ImageCanvas.render(width: width, height: height) {
            scheme.background.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: self.width, height: self.height)).fill()

            let topBorder = NSBezierPath()
            topBorder.lineWidth = 2
            for i in 0..<3 {
                topBorder.move(to: NSPoint(x: 50, y: topBorderY + CGFloat(i)))
                topBorder.line(to: NSPoint(x: CGFloat(self.width) - 50, y: topBorderY + CGFloat(i)))
            }
            scheme.accent.setStroke()
            topBorder.stroke()

            // drawCentered's `y` lands at the *bottom* of each line's glyphs
            // (they extend upward from it), so the first line's y needs to
            // start a full line height below the border gap, not right at it
            // — otherwise a large font's ascenders reach up past the border.
            var currentY = topBorderY + borderToTextGap + fitted.lineHeight
            for line in fitted.lines {
                drawCentered(line, font: fitted.font, color: scheme.text, y: currentY, canvasWidth: self.width)
                currentY += fitted.lineHeight
            }

            let bottomBorder = NSBezierPath()
            bottomBorder.lineWidth = 2
            let bottomLineY = topBorderY + borderToTextGap + textHeight + textToBorderGap
            for i in 0..<3 {
                bottomBorder.move(to: NSPoint(x: 50, y: bottomLineY + CGFloat(i)))
                bottomBorder.line(to: NSPoint(x: CGFloat(self.width) - 50, y: bottomLineY + CGFloat(i)))
            }
            scheme.accent.setStroke()
            bottomBorder.stroke()

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM d, yyyy"
            drawCentered(dateFormatter.string(from: Date()), font: dateFont, color: scheme.accent, y: bottomLineY + borderToDateGap, canvasWidth: self.width)
        }
    }
}
