import Foundation

/// Small text clean-ups shared by the generated-content sources and the
/// museum cards.
public enum TextCleaning {
    /// "Laura &amp; Viva" → "Laura & Viva": decodes the HTML entities a copy
    /// from a web page can drag along (`&amp;`, `&quot;`, `&#8217;`, `&nbsp;`…).
    public static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result), let codeRange = Range(match.range(at: 1), in: result) else { continue }
                let code = result[codeRange]
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code, radix: 10)
                if let value, let scalar = Unicode.Scalar(value) {
                    result.replaceSubrange(whole, with: String(Character(scalar)))
                }
            }
        }
        // `&amp;` last, so "&amp;lt;" becomes "&lt;" rather than "<".
        let named = [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
