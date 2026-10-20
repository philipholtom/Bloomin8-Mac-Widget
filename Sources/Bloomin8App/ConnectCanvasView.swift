import Bloomin8Core
import SwiftUI
import os

/// A device picker for the frame's Bluetooth name, styled after the BLOOMIN8
/// phone app's own "Connect Canvas" screen. Live CoreBluetooth scan (backed
/// by `BLEScanner`) scoped to BLOOMIN8 frames specifically, rather than a
/// mock list or every nearby Bluetooth device.
///
/// Picking a device does two real things, not just fills in a name: sends a
/// BLE wake pulse (`BLEWaker`) so the frame's Wi-Fi radio is up, then sweeps
/// the local subnet (`FrameIPDiscovery`) for the IP whose `/deviceInfo` name
/// matches — so both the Bluetooth name and IP address fields get filled in
/// from one tap.
struct ConnectCanvasView: View {
    private static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "connect-canvas")

    @StateObject private var scanner = BLEScanner()
    @Environment(\.dismiss) private var dismiss

    /// Called once BLE wake + IP discovery finish. `ip` is nil if the frame
    /// woke but couldn't be found on the network (still worth keeping the
    /// name, just not the IP).
    let onSelect: (_ name: String, _ ip: String?) -> Void

    @State private var searchText = ""
    @State private var sortMode: SortMode = .name
    @State private var connectingTo: DiscoveredDevice?
    @State private var connectStatus = ""
    @State private var connectFailed = false

    private enum SortMode {
        case name, signal
    }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor).ignoresSafeArea()

            VStack(spacing: 28) {
                header
                card

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(.top, 40)
            .padding(.horizontal, 40)
            .disabled(connectingTo != nil)
            .opacity(connectingTo != nil ? 0.25 : 1)

            if let connectingTo {
                connectingOverlay(connectingTo)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640, idealHeight: 700)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("Connect Canvas")
                .font(.system(size: 34, weight: .bold))
            Text("Select a device to begin customization")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            sortRow
            Divider()
            deviceList
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .frame(maxWidth: 480)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search devices", text: $searchText)
                .textFieldStyle(.plain)
            Image(systemName: scanner.isScanning ? "wifi" : "wifi.slash")
                .foregroundStyle(.secondary)
                .help(scanner.isScanning ? "Scanning" : "Not scanning")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sortRow: some View {
        HStack(spacing: 8) {
            Text("Sort")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            sortPill("Name", isSelected: sortMode == .name) { sortMode = .name }
            sortPill("Signal", isSelected: sortMode == .signal) { sortMode = .signal }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sortPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var deviceList: some View {
        if scanner.permissionDenied {
            statusMessage("Bluetooth permission denied.\nEnable it for Bloomin8 Mac in System Settings \u{2192} Privacy & Security \u{2192} Bluetooth.")
        } else if filteredDevices.isEmpty {
            statusMessage(scanner.isScanning ? "Scanning for nearby canvases\u{2026}" : "No devices found.")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredDevices) { device in
                        deviceRow(device)
                        if device.id != filteredDevices.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func statusMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 20)
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        Button {
            connect(to: device)
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(device.name.prefix(1).uppercased())
                            .font(.system(size: 15, weight: .semibold))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(detailLine(device))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detailLine(_ device: DiscoveredDevice) -> String {
        var parts = ["Signal: \(device.rssi) dBm"]
        if let battery = device.batteryPercent {
            parts.append("Battery: \(battery)%")
        }
        return parts.joined(separator: "   ")
    }

    private var filteredDevices: [DiscoveredDevice] {
        let base = searchText.isEmpty
            ? scanner.devices
            : scanner.devices.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        switch sortMode {
        case .name:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .signal:
            return base.sorted { $0.rssi > $1.rssi }
        }
    }

    // MARK: - Connect flow (wake over BLE, then find the IP on the network)

    private func connectingOverlay(_ device: DiscoveredDevice) -> some View {
        VStack(spacing: 16) {
            if connectFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Text(connectFailed ? "Couldn't find \u{201C}\(device.name)\u{201D} on your network" : connectStatus)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if connectFailed {
                HStack(spacing: 12) {
                    Button("Try Again") { connect(to: device) }
                    Button("Use Name Only") {
                        onSelect(device.name, nil)
                        dismiss()
                    }
                    Button("Cancel") { connectingTo = nil }
                }
            }
        }
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 20)
    }

    private func connect(to device: DiscoveredDevice) {
        connectFailed = false
        connectStatus = "Waking \u{201C}\(device.name)\u{201D}\u{2026}"
        connectingTo = device
        Task {
            Self.log.notice("connect: start '\(device.name, privacy: .public)'")
            let waker = BLEWaker()
            let woke = await waker.wake(deviceName: device.name)
            Self.log.notice("connect: wake pulse sent=\(woke)")

            connectStatus = "Finding it on your network\u{2026}"
            let ip = await FrameIPDiscovery.findIP(matchingName: device.name)
            Self.log.notice("connect: discovery result ip=\(ip ?? "nil", privacy: .public)")

            if let ip {
                onSelect(device.name, ip)
                dismiss()
            } else {
                connectFailed = true
            }
        }
    }
}
