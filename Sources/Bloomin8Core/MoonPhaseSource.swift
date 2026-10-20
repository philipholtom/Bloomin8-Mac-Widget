import AppKit

/// A moon-phase visualization computed purely from astronomical math — no
/// network call. Ported from moon_phase_uploader.py, which used PyEphem
/// (no direct Swift/Apple-framework equivalent); this hand-rolls the
/// standard age/synodic-month approximation instead, accurate to well
/// within a day, which is plenty for a decorative display.
public struct MoonPhaseSource: ContentSource {
    public let id = "moon"
    public let displayName = "Moon Phase"
    public let galleryName = "Moon Phase"

    private let width = 1200
    private let height = 1600
    private let synodicMonth = 29.530588853

    private struct MoonPhaseData {
        let phaseName: String
        let illumination: Double // 0...1
        let illuminationPercent: Int
        let daysToFull: Int
        let daysToNew: Int
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        let phase = calculatePhase()
        guard let image = renderArt(phase: phase), let jpeg = ImageCanvas.jpegData(image) else {
            throw ContentSourceError.message("Couldn't render moon phase image")
        }
        return jpeg
    }

    /// The original script named the phase from illumination alone, which
    /// can't actually distinguish waxing from waning (illumination is
    /// symmetric across the cycle — the same value occurs once on the way
    /// up and once on the way down). This instead names the phase from
    /// where in the cycle we are (age / synodic month), which is what a
    /// phase name should reflect; illumination is still reported separately
    /// for the "% illuminated" display.
    private func calculatePhase(at date: Date = Date()) -> MoonPhaseData {
        var referenceComponents = DateComponents()
        referenceComponents.year = 2000
        referenceComponents.month = 1
        referenceComponents.day = 6
        referenceComponents.hour = 18
        referenceComponents.minute = 14
        referenceComponents.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        let referenceNewMoon = calendar.date(from: referenceComponents) ?? date

        let daysSinceReference = date.timeIntervalSince(referenceNewMoon) / 86400
        var age = daysSinceReference.truncatingRemainder(dividingBy: synodicMonth)
        if age < 0 { age += synodicMonth }
        let phaseFraction = age / synodicMonth

        let illumination = (1 - cos(2 * Double.pi * phaseFraction)) / 2
        let phaseNames = [
            "New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
            "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"
        ]
        let phaseIndex = Int((phaseFraction * 8).rounded()) % 8
        let daysToFull = phaseFraction < 0.5 ? (0.5 - phaseFraction) * synodicMonth : (1.5 - phaseFraction) * synodicMonth
        let daysToNew = (1.0 - phaseFraction) * synodicMonth

        return MoonPhaseData(
            phaseName: phaseNames[phaseIndex],
            illumination: illumination,
            illuminationPercent: Int((illumination * 100).rounded()),
            daysToFull: Int(daysToFull.rounded()),
            daysToNew: Int(daysToNew.rounded())
        )
    }

    private func renderArt(phase: MoonPhaseData) -> NSImage? {
        ImageCanvas.render(width: width, height: height) {
            NSColor(red: 10/255, green: 15/255, blue: 35/255, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: self.width, height: self.height)).fill()

            let titleFont = NSFont(name: "Helvetica", size: 48) ?? NSFont.systemFont(ofSize: 48)
            let infoFont = NSFont(name: "Helvetica", size: 32) ?? NSFont.systemFont(ofSize: 32)
            let detailFont = NSFont(name: "Helvetica", size: 24) ?? NSFont.systemFont(ofSize: 24)

            drawCentered("Moon Phase", font: titleFont, color: NSColor(red: 200/255, green: 200/255, blue: 255/255, alpha: 1), y: 80, canvasWidth: self.width)

            let centerX = CGFloat(self.width) / 2
            let centerY = CGFloat(self.height) / 2 - 100
            let radius: CGFloat = 200
            let circleRect = NSRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2)

            NSColor(red: 30/255, green: 30/255, blue: 60/255, alpha: 1).setFill()
            NSBezierPath(ovalIn: circleRect).fill()
            let outline = NSBezierPath(ovalIn: circleRect)
            outline.lineWidth = 4
            NSColor(red: 150/255, green: 200/255, blue: 255/255, alpha: 1).setStroke()
            outline.stroke()

            // Lit portion: an ellipse narrower than the base circle, offset
            // to one side — the same two-overlapping-ellipses illusion the
            // original PIL code used, not a true rectangular clip.
            if phase.illumination > 0.01 {
                NSColor(red: 200/255, green: 200/255, blue: 150/255, alpha: 1).setFill()
                if phase.illumination < 0.5 {
                    // Waxing: light from the right.
                    let shadowWidth = radius * 2 * (1 - phase.illumination * 2)
                    let litX = centerX - radius + shadowWidth
                    let litRect = NSRect(x: litX, y: centerY - radius, width: (centerX + radius) - litX, height: radius * 2)
                    NSBezierPath(ovalIn: litRect).fill()
                } else {
                    // Waning: light from the left.
                    let shadowWidth = radius * 2 * (phase.illumination * 2 - 1)
                    let litRect = NSRect(x: centerX - radius, y: centerY - radius, width: radius * 2 - shadowWidth, height: radius * 2)
                    NSBezierPath(ovalIn: litRect).fill()
                }
            }

            drawCentered(phase.phaseName, font: infoFont, color: NSColor(red: 150/255, green: 200/255, blue: 255/255, alpha: 1), y: centerY + radius + 80, canvasWidth: self.width)
            drawCentered("\(phase.illuminationPercent)% Illuminated", font: detailFont, color: NSColor(red: 200/255, green: 200/255, blue: 150/255, alpha: 1), y: centerY + radius + 150, canvasWidth: self.width)

            let infoY = CGFloat(self.height) - 280
            drawCentered("Days until Full Moon: \(phase.daysToFull)", font: detailFont, color: NSColor(red: 180/255, green: 180/255, blue: 255/255, alpha: 1), y: infoY, canvasWidth: self.width)
            drawCentered("Days until New Moon: \(phase.daysToNew)", font: detailFont, color: NSColor(red: 180/255, green: 180/255, blue: 255/255, alpha: 1), y: infoY + 50, canvasWidth: self.width)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM d, yyyy"
            drawCentered(dateFormatter.string(from: Date()), font: detailFont, color: NSColor(red: 150/255, green: 150/255, blue: 200/255, alpha: 1), y: CGFloat(self.height) - 60, canvasWidth: self.width)
        }
    }
}
