import Bloomin8Core
import AppKit
import SwiftUI

/// Asks for a backup: which galleries and where, then shows progress.
struct BackupRequest: Identifiable {
    let id = UUID()
    /// Galleries ticked to begin with; nil means all of them.
    var preselected: Set<String>?
}

/// Copies whole galleries from the frame to a folder on this Mac. Running it
/// again into the same folder only copies what's new.
struct BackupSheet: View {
    let request: BackupRequest
    @ObservedObject var controller: PhotoController
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case setup
        case running
        case done
    }

    @AppStorage("backupFolderPath") private var folderPath = ""
    @State private var stage: Stage = .setup
    @State private var chosen: Set<String> = []
    @State private var progress: BackupProgress?
    @State private var result: BackupResult?
    @State private var task: Task<Void, Never>?

    /// Locked galleries stay out of reach unless unlocked — same rule as the sidebar.
    private var available: [String] {
        controller.galleries.filter { settings.lockedTab(for: $0, unlockedTabIDs: controller.unlockedTabIDs) == nil }
    }

    private var frameName: String {
        PhotoController.pathSafe(settings.frameProfiles.first(where: { $0.id == settings.activeFrameProfileID })?.name ?? "Frame")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Back Up Galleries")
                .font(.headline)

            switch stage {
            case .setup: setupContent
            case .running: runningContent
            case .done: doneContent
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            chosen = request.preselected.map { $0.intersection(available) } ?? Set(available)
        }
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if available.isEmpty {
                Text("No galleries loaded yet — wake the frame and press Refresh.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Galleries")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { chosen = Set(available) }
                        .buttonStyle(.link)
                    Button("None") { chosen = [] }
                        .buttonStyle(.link)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(available, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { chosen.contains(name) },
                                set: { on in if on { chosen.insert(name) } else { chosen.remove(name) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text(folderPath.isEmpty ? "No folder chosen" : folderPath)
                    .font(.caption)
                    .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") {
                    if let folder = FilePicker.chooseFolder(title: "Choose Where to Save the Backup") {
                        folderPath = folder.path
                    }
                }
            }

            Text("Saved in “Blooming8 Backup / \(frameName)” inside that folder, one subfolder per gallery. Run it again any time and only new photos are copied. The frame is slow, so a big gallery can take a good few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start Backup") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || folderPath.isEmpty || settings.deviceIP.isEmpty)
            }
        }
    }

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress {
                Text("Gallery \(progress.galleryIndex) of \(progress.galleryCount): \(progress.gallery)")
                    .font(.callout)
                if progress.fileCount > 0 {
                    ProgressView(value: Double(progress.fileIndex), total: Double(progress.fileCount))
                    Text("Photo \(progress.fileIndex) of \(progress.fileCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Listing the photos…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(progress.downloaded) copied · \(progress.skipped) already there" + (progress.failed > 0 ? " · \(progress.failed) failed" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button("Stop") { task?.cancel() }
            }
        }
        .frame(minHeight: 110)
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                Label(result.cancelled ? "Stopped early" : "Backup finished", systemImage: result.cancelled ? "pause.circle" : "checkmark.circle")
                    .font(.callout.weight(.medium))
                Text("\(result.galleries) galler\(result.galleries == 1 ? "y" : "ies"): \(result.downloaded) copied, \(result.skipped) already there" + (result.failed > 0 ? ", \(result.failed) couldn't be copied (run it again to retry them)" : "") + ".")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let result {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.folder])
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func start() {
        guard !folderPath.isEmpty else { return }
        let destination = URL(fileURLWithPath: folderPath, isDirectory: true)
        let names = available.filter { chosen.contains($0) }
        stage = .running
        task = Task {
            let outcome = await controller.backupGalleries(names, to: destination) { progress = $0 }
            result = outcome
            stage = .done
        }
    }
}
