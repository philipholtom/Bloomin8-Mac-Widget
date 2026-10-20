import Bloomin8Core
import SwiftUI

/// What the frame reports about itself, buttons for its system commands
/// (sleep, clear the screen, restart) and its on-device logging switch.
struct FrameControlsView: View {
    @ObservedObject var controller: PhotoController

    @State private var taskStatus: String?
    @State private var logOn = true
    @State private var logKeepDays = 7
    @State private var logConfigLoaded = false
    @State private var confirming: Command?
    @State private var confirmingDeleteLogs = false
    @State private var logMessage: String?

    private enum Command: Identifiable {
        case sleep, clear, reboot
        var id: Self { self }
        var title: String {
            switch self {
            case .sleep: return "Put the frame to sleep now?"
            case .clear: return "Clear the screen to white?"
            case .reboot: return "Restart the frame?"
            }
        }
        var detail: String {
            switch self {
            case .sleep: return "It will sleep until woken by Bluetooth, a button or its schedule."
            case .clear: return "The picture is removed from the screen until you show another one. Useful for ghosting or long storage."
            case .reboot: return "It's unreachable for a short while as it restarts."
            }
        }
    }

    private var asleep: Bool { controller.isDeviceAwake == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if asleep {
                Label("The frame is asleep — wake it (toolbar) to see its status or use these controls.", systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            statusRows
            Divider()
            buttons
            Divider()
            loggingControls
        }
        .task { await reload() }
        .onChange(of: controller.isDeviceAwake) { awake in
            if awake == true { Task { await reload() } }
        }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let command = confirming {
                Button(command == .reboot ? "Restart" : command == .sleep ? "Sleep now" : "Clear screen", role: command == .sleep ? nil : .destructive) {
                    Task {
                        switch command {
                        case .sleep: await controller.sleepFrameNow()
                        case .clear: await controller.clearFrameScreen()
                        case .reboot: await controller.rebootFrame()
                        }
                    }
                }
            }
        } message: {
            Text(confirming?.detail ?? "")
        }
        .confirmationDialog("Delete all of the frame's logs?", isPresented: $confirmingDeleteLogs) {
            Button("Delete logs", role: .destructive) {
                Task { logMessage = await controller.deleteAllFrameLogs() ? "Logs deleted." : controller.statusText }
            }
        } message: {
            Text("This removes every log file stored on the frame. It can't be undone.")
        }
    }

    // MARK: - Status

    private var statusRows: some View {
        let info = controller.deviceInfo
        return VStack(alignment: .leading, spacing: 6) {
            row("Firmware", info?.version)
            row("Screen", info?.screenModel)
            row("Wi-Fi", wifiText(info))
            row("Storage", storageText(info))
            row("Now playing", playbackText(info))
            row("Next wake", nextWakeText(info))
            row("Status", taskStatus)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func wifiText(_ info: DeviceInfo?) -> String? {
        guard let info else { return nil }
        guard info.networkType != 0 else { return "Not connected" }
        var parts: [String] = []
        if let ssid = info.staSSID, !ssid.isEmpty { parts.append(ssid) }
        if let rssi = info.staRSSI { parts.append("\(rssi) dBm") }
        if let ip = info.staIP, !ip.isEmpty { parts.append(ip) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func storageText(_ info: DeviceInfo?) -> String? {
        guard let total = info?.totalSize, total > 0, let free = info?.freeSize else { return nil }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "\(fmt.string(fromByteCount: Int64(free))) free of \(fmt.string(fromByteCount: Int64(total)))"
    }

    private func playbackText(_ info: DeviceInfo?) -> String? {
        guard let info, let type = info.playType else { return nil }
        switch type {
        case 1: return "Slideshow of '\(info.gallery ?? "?")' every \((info.playDuration ?? 0) / 60) min"
        case 2: return "Playlist '\(info.playlist ?? "?")'"
        default: return "A single photo"
        }
    }

    private func nextWakeText(_ info: DeviceInfo?) -> String? {
        guard let next = info?.nextTime, next > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(next))
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Button("Sleep now") { confirming = .sleep }
            Button("Clear screen") { confirming = .clear }
            Button("Restart") { confirming = .reboot }
        }
        .disabled(asleep || controller.isBusy)
    }

    // MARK: - Logging

    private var loggingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep a diagnostic log on the frame", isOn: $logOn)
                .disabled(asleep || !logConfigLoaded)
            LabeledContent("Keep logs for") {
                HStack {
                    Stepper(value: $logKeepDays, in: 0...90) {
                        Text(logKeepDays == 0 ? "Forever" : "\(logKeepDays) days")
                    }
                }
            }
            .disabled(asleep || !logConfigLoaded)
            HStack {
                Button("Save logging settings") {
                    Task {
                        logMessage = await controller.updateLogConfig(logOn: logOn, keepDays: logKeepDays)
                            ? "Saved to the frame." : controller.statusText
                    }
                }
                Button("Delete all logs…", role: .destructive) { confirmingDeleteLogs = true }
            }
            .disabled(asleep || !logConfigLoaded || controller.isBusy)
            if let logMessage {
                Text(logMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        guard !asleep else { return }
        taskStatus = await controller.fetchTaskStatus()
        if let config = await controller.fetchLogConfig() {
            logOn = config.logOn
            logKeepDays = config.logKeepDays
            logConfigLoaded = true
        }
    }
}
