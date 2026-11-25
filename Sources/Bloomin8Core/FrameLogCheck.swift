import Foundation

/// Reads the frame's own log to tell whether a picture it was sent actually
/// got drawn. The frame records the new picture as current as soon as the
/// upload finishes, even when the display step then fails, so its status
/// can't be trusted for this.
public enum FrameLogCheck {
    public enum DisplayState: Equatable {
        /// The frame logged showing it, with no failure afterwards.
        case shown
        /// The frame logged a parsing failure and never showed it afterwards.
        case failed
        /// Neither yet: still being written or drawn, or the log has no trace of it.
        case pending
    }

    /// What happened to `path` after the frame last started receiving or
    /// showing it. Uses line order only, so the frame's clock doesn't matter.
    public static func displayState(in log: String, path: String) -> DisplayState {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        // The /show command logs its JSON body, where slashes are escaped.
        let escaped = path.replacingOccurrences(of: "/", with: "\\/")
        guard let start = lines.lastIndex(where: {
            $0.contains("Start upload: \(path)") || ($0.contains("Start show:") && $0.contains(escaped))
        }) else { return .pending }
        let after = lines[(start + 1)...]
        let lastFailure = after.lastIndex { $0.contains("Image parsing failed") }
        let lastShow = after.lastIndex { $0.contains("Show image: \(path)") }
        switch (lastFailure, lastShow) {
        case (nil, nil): return .pending
        case (nil, .some): return .shown
        case (.some, nil): return .failed
        case let (.some(failure), .some(show)): return show > failure ? .shown : .failed
        }
    }
}
