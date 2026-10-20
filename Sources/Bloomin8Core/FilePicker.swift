import AppKit
import UniformTypeIdentifiers

/// Thin wrappers around NSOpenPanel for picking photos to upload or a
/// destination folder to download into. The app isn't sandboxed, so no
/// security-scoped bookmarks are needed — the panel itself is just the UX
/// for getting file URLs from the user.
public enum FilePicker {
    public static func chooseImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose Photos to Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .gif, .bmp, .heic, .image]
        return panel.runModal() == .OK ? panel.urls : []
    }

    public static func chooseFolder(title: String = "Choose a Folder to Save Photos Into") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
