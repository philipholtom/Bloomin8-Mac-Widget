import AppKit

/// A random periodic table element, with a representative photo fetched
/// from Wikimedia Commons where one can be found. Ported from
/// periodic_table_uploader.py.
public struct PeriodicTableSource: ContentSource {
    public let id = "periodicTable"
    public let displayName = "Periodic Table"
    public let galleryName = "Periodic Table"

    private let width = 1200
    private let height = 1600

    private struct ColorScheme {
        let background: NSColor
        let text: NSColor
        let accent: NSColor
    }

    private static let colorSchemes: [ColorScheme] = [
        ColorScheme(background: NSColor(red: 40/255, green: 50/255, blue: 80/255, alpha: 1), text: NSColor(red: 200/255, green: 220/255, blue: 255/255, alpha: 1), accent: NSColor(red: 150/255, green: 200/255, blue: 255/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 80/255, green: 50/255, blue: 30/255, alpha: 1), text: NSColor(red: 255/255, green: 220/255, blue: 180/255, alpha: 1), accent: NSColor(red: 255/255, green: 180/255, blue: 100/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 60/255, green: 30/255, blue: 80/255, alpha: 1), text: NSColor(red: 220/255, green: 180/255, blue: 255/255, alpha: 1), accent: NSColor(red: 180/255, green: 140/255, blue: 255/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 100/255, green: 140/255, blue: 200/255, alpha: 1), text: NSColor(red: 240/255, green: 250/255, blue: 255/255, alpha: 1), accent: NSColor(red: 200/255, green: 220/255, blue: 255/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 150/255, green: 100/255, blue: 180/255, alpha: 1), text: NSColor(red: 245/255, green: 240/255, blue: 255/255, alpha: 1), accent: NSColor(red: 220/255, green: 180/255, blue: 255/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 80/255, green: 140/255, blue: 120/255, alpha: 1), text: NSColor(red: 240/255, green: 255/255, blue: 250/255, alpha: 1), accent: NSColor(red: 150/255, green: 220/255, blue: 200/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 180/255, green: 120/255, blue: 100/255, alpha: 1), text: NSColor(red: 255/255, green: 240/255, blue: 235/255, alpha: 1), accent: NSColor(red: 255/255, green: 160/255, blue: 120/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 100/255, green: 150/255, blue: 100/255, alpha: 1), text: NSColor(red: 240/255, green: 255/255, blue: 240/255, alpha: 1), accent: NSColor(red: 180/255, green: 220/255, blue: 180/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 160/255, green: 130/255, blue: 80/255, alpha: 1), text: NSColor(red: 255/255, green: 250/255, blue: 240/255, alpha: 1), accent: NSColor(red: 220/255, green: 190/255, blue: 140/255, alpha: 1)),
        ColorScheme(background: NSColor(red: 120/255, green: 100/255, blue: 150/255, alpha: 1), text: NSColor(red: 245/255, green: 240/255, blue: 255/255, alpha: 1), accent: NSColor(red: 190/255, green: 160/255, blue: 220/255, alpha: 1)),
    ]

    private struct CommonsSearchResponse: Decodable {
        struct Query: Decodable {
            struct SearchResult: Decodable { let title: String }
            let search: [SearchResult]
        }
        let query: Query
    }

    private struct CommonsImageInfoResponse: Decodable {
        struct Query: Decodable {
            struct Page: Decodable {
                struct ImageInfo: Decodable { let url: String; let mime: String }
                let imageinfo: [ImageInfo]?
            }
            let pages: [String: Page]
        }
        let query: Query
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        guard let element = PeriodicElements.all.randomElement() else {
            throw ContentSourceError.message("No elements available")
        }
        let elementImage = await fetchElementImage(name: element.name, symbol: element.symbol)
        guard let image = renderArt(element: element, elementImage: elementImage), let jpeg = ImageCanvas.jpegData(image) else {
            throw ContentSourceError.message("Couldn't render periodic table image")
        }
        return jpeg
    }

    /// Best-effort: tries a few search terms against Wikimedia Commons and
    /// returns the first plausible photo, skipping obvious diagrams/SVGs.
    /// Returns nil (rather than throwing) on any failure — the original
    /// script just omits the image in that case rather than failing outright.
    private func fetchElementImage(name: String, symbol: String) async -> NSImage? {
        let searchTerms = ["\(symbol) (element)", "\(name) element", name, symbol]
        let skipKeywords = ["diagram", "category", "periodic", "table", "spectrum", "svg"]
        let acceptedMimeTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

        for term in searchTerms {
            var searchComponents = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
            searchComponents.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "list", value: "search"),
                URLQueryItem(name: "srsearch", value: term),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "srnamespace", value: "6"),
                URLQueryItem(name: "srlimit", value: "10")
            ]
            var searchRequest = URLRequest(url: searchComponents.url!)
            searchRequest.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")

            guard let (searchData, _) = try? await URLSession.shared.data(for: searchRequest),
                  let searchResult = try? JSONDecoder().decode(CommonsSearchResponse.self, from: searchData)
            else { continue }

            for result in searchResult.query.search {
                let lowerTitle = result.title.lowercased()
                if skipKeywords.contains(where: { lowerTitle.contains($0) }) { continue }

                var infoComponents = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
                infoComponents.queryItems = [
                    URLQueryItem(name: "action", value: "query"),
                    URLQueryItem(name: "titles", value: result.title),
                    URLQueryItem(name: "prop", value: "imageinfo"),
                    URLQueryItem(name: "iiprop", value: "url|mime"),
                    URLQueryItem(name: "format", value: "json")
                ]
                var infoRequest = URLRequest(url: infoComponents.url!)
                infoRequest.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")

                guard let (infoData, _) = try? await URLSession.shared.data(for: infoRequest),
                      let infoResult = try? JSONDecoder().decode(CommonsImageInfoResponse.self, from: infoData)
                else { continue }

                for page in infoResult.query.pages.values {
                    guard let info = page.imageinfo?.first,
                          acceptedMimeTypes.contains(info.mime),
                          let imageURL = URL(string: info.url),
                          let (imageData, _) = try? await URLSession.shared.data(from: imageURL),
                          let image = NSImage(data: imageData)
                    else { continue }
                    return image
                }
            }
        }
        return nil
    }

    private func renderArt(element: PeriodicElement, elementImage: NSImage?) -> NSImage? {
        let scheme = Self.colorSchemes.randomElement()!

        return ImageCanvas.render(width: width, height: height) {
            scheme.background.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: self.width, height: self.height)).fill()

            let nameFont = NSFont(name: "Helvetica", size: 100) ?? NSFont.systemFont(ofSize: 100)
            let symbolFont = NSFont(name: "Helvetica", size: 280) ?? NSFont.systemFont(ofSize: 280)
            let infoFont = NSFont(name: "Helvetica", size: 52) ?? NSFont.systemFont(ofSize: 52)
            let factsFont = NSFont(name: "Helvetica", size: 28) ?? NSFont.systemFont(ofSize: 28)
            let dateFont = NSFont(name: "Helvetica", size: 24) ?? NSFont.systemFont(ofSize: 24)

            drawCentered(element.name, font: nameFont, color: scheme.accent, y: 60, canvasWidth: self.width)
            drawCentered(element.symbol, font: symbolFont, color: scheme.text, y: 250, canvasWidth: self.width)

            var y: CGFloat = 650
            drawCentered("#\(element.atomicNumber)", font: infoFont, color: scheme.text, y: y, canvasWidth: self.width)
            y += 65
            drawCentered("Wt: \(element.atomicWeight)", font: infoFont, color: scheme.text, y: y, canvasWidth: self.width)

            var bottomY: CGFloat = 850
            if let elementImage {
                let imageSize: CGFloat = 300
                let imageRect = NSRect(x: (CGFloat(self.width) - imageSize) / 2, y: bottomY, width: imageSize, height: imageSize)
                drawImage(elementImage, in: imageRect)
                bottomY += imageSize + 40
            }

            let wrappedFacts = wrapText(element.facts, maxCharsPerLine: 65, maxLines: 3)
            for line in wrappedFacts {
                drawCentered(line, font: factsFont, color: scheme.text, y: bottomY, canvasWidth: self.width)
                bottomY += 30
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM d, yyyy"
            drawCentered(dateFormatter.string(from: Date()), font: dateFont, color: scheme.accent, y: CGFloat(self.height) - 40, canvasWidth: self.width)
        }
    }
}
