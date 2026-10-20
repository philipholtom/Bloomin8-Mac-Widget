import CoreBluetooth
import Foundation
import os

/// Sends a Bluetooth "wake" pulse to a Bloomin8 frame so its Wi-Fi radio
/// comes back up after it's gone to sleep: scan for the frame by its
/// advertised name, connect, discover services, and write a 0x01-then-0x00
/// pulse to its wake characteristic.
///
/// The pulse details (which characteristic, write type, gap) follow ARPOBOT's
/// own Home Assistant integration — see `ble_wake.py` and `const.py` in
/// ARPOBOT-BLOOMIN8/eink_canvas_home_assistant_component.
///
/// Every step logs to the unified log; BLE failures are otherwise invisible
/// (no error surfaces, the frame just stays asleep). To watch a wake attempt:
///
///     log stream --predicate 'subsystem == "com.pholtom.blooming8widget"'
@MainActor
public final class BLEWaker: NSObject {
    private static let log = Logger(subsystem: "com.pholtom.blooming8widget", category: "ble")

    /// The wake pulse goes only to 0xF001 (in the 0xF000 service). The frame
    /// also exposes 0xFFF1 in its 0xFFF0 service, but that's a Notify
    /// characteristic: ARPOBOT found that writing to it confuses the firmware
    /// and can break the notify stream, and dropped it in favour of 0xF001
    /// alone. 0xFFF0 is for advertisement discovery, not a wake target.
    private static let wakeCharUUID = CBUUID(string: "0000F001-0000-1000-8000-00805F9B34FB")

    /// Budget for connect + service discovery + pulse, armed once the frame
    /// has been found. Bounded separately from the scan so a frame that stops
    /// responding mid-handshake can't hold a half-open link and block other
    /// BLE clients (the phone app) from connecting.
    private static let connectTimeout: TimeInterval = 6

    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    private var targetName = ""
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didPulseCharacteristic = false
    private var isPulsing = false
    private var pendingServices = 0
    private var loggedNames = Set<String>()

    /// Scans for a BLE peripheral advertising `deviceName`, connects, and writes
    /// a wake pulse to its known characteristic. Returns true once the pulse was
    /// sent — not a guarantee the frame actually woke, just that the BLE side of
    /// things succeeded.
    public func wake(deviceName: String, scanTimeout: TimeInterval = 20) async -> Bool {
        guard continuation == nil else {
            Self.log.error("wake: ignored, a wake is already in progress")
            return false
        }
        guard !deviceName.isEmpty else {
            Self.log.error("wake: ignored, no device name configured")
            return false
        }

        targetName = deviceName
        didPulseCharacteristic = false
        isPulsing = false
        pendingServices = 0
        loggedNames.removeAll()

        Self.log.notice("wake: start, target='\(deviceName, privacy: .public)' scanTimeout=\(scanTimeout)s")
        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.centralManager = CBCentralManager(delegate: self, queue: nil)
            self.armTimeout(scanTimeout, phase: "scan")
        }
    }

    /// (Re)arms the give-up timer. The scan gets the caller's full budget;
    /// once the frame has been found, the connect phase gets its own shorter
    /// one, so a slow scan doesn't leave the link hanging afterwards.
    private func armTimeout(_ seconds: TimeInterval, phase: String) {
        timeoutTask?.cancel()
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return } // superseded by a re-arm
            Self.log.error("timeout: \(phase, privacy: .public) phase exceeded \(seconds)s")
            self.finish(false)
        }
    }

    private func finish(_ success: Bool) {
        guard let cont = continuation else { return }
        Self.log.notice("finish: success=\(success)")
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        centralManager?.stopScan()
        if let peripheral = targetPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        targetPeripheral = nil
        centralManager = nil
        cont.resume(returning: success)
    }

    private func pulseAndDisconnect(characteristic: CBCharacteristic, peripheral: CBPeripheral) async {
        didPulseCharacteristic = true
        Self.log.notice("pulse: writing 0x01/0x00 withoutResponse to \(characteristic.uuid.uuidString, privacy: .public)")
        // Always writeWithoutResponse, regardless of what the characteristic
        // declares. Some firmware exposes only Write Command, where waiting on
        // a response costs ~2s per wake before timing out and falling back.
        peripheral.writeValue(Data([0x01]), for: characteristic, type: .withoutResponse)
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms assert -> release gap
        peripheral.writeValue(Data([0x00]), for: characteristic, type: .withoutResponse)
        // Unlike bleak, CoreBluetooth's withoutResponse writes are queued
        // fire-and-forget with no completion callback, so give them a moment to
        // reach the air before tearing the link down under them.
        try? await Task.sleep(nanoseconds: 100_000_000)
        Self.log.notice("pulse: sent, disconnecting")
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    private static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.writeWithoutResponse) { parts.append("writeWithoutResponse") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }
}

extension BLEWaker: @MainActor CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            Self.log.notice("central: poweredOn, scanning")
            central.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            Self.log.error("central: unauthorized — Bluetooth permission denied for this app")
            finish(false)
        case .unsupported:
            Self.log.error("central: unsupported")
            finish(false)
        case .poweredOff:
            Self.log.error("central: poweredOff")
            finish(false)
        default:
            Self.log.debug("central: state=\(central.state.rawValue)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        if let seen = advertisedName, !loggedNames.contains(seen) {
            loggedNames.insert(seen)
            Self.log.debug("scan: saw '\(seen, privacy: .public)' rssi=\(RSSI.intValue)")
        }
        guard let name = advertisedName, name.caseInsensitiveCompare(targetName) == .orderedSame else { return }

        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ",") ?? "none"
        Self.log.notice("scan: MATCH '\(name, privacy: .public)' rssi=\(RSSI.intValue) advServices=\(services, privacy: .public)")

        central.stopScan()
        targetPeripheral = peripheral
        peripheral.delegate = self
        armTimeout(Self.connectTimeout, phase: "connect")
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Self.log.notice("connect: ok, discovering services")
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Self.log.error("connect: failed — \(error?.localizedDescription ?? "unknown", privacy: .public)")
        finish(false)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Self.log.notice("disconnect: pulsed=\(self.didPulseCharacteristic) err=\(error?.localizedDescription ?? "none", privacy: .public)")
        finish(didPulseCharacteristic)
    }
}

extension BLEWaker: @MainActor CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            Self.log.error("services: discovery failed — \(error?.localizedDescription ?? "no services", privacy: .public)")
            finish(false)
            return
        }
        let list = services.map(\.uuid.uuidString).joined(separator: ",")
        Self.log.notice("services: \(services.count) found — \(list, privacy: .public)")
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        guard error == nil, let characteristics = service.characteristics else {
            Self.log.error("chars: \(service.uuid.uuidString, privacy: .public) failed — \(error?.localizedDescription ?? "none", privacy: .public)")
            return
        }
        for characteristic in characteristics {
            Self.log.notice("chars: \(service.uuid.uuidString, privacy: .public)/\(characteristic.uuid.uuidString, privacy: .public) [\(Self.describe(characteristic.properties), privacy: .public)]")
        }
        guard let wakeCharacteristic = characteristics.first(where: { $0.uuid == Self.wakeCharUUID }) else {
            // Not in this service. If that was the last one, the frame doesn't
            // expose the wake characteristic at all — say so rather than
            // silently waiting out the connect timeout.
            if pendingServices <= 0, !isPulsing {
                Self.log.error("chars: wake characteristic \(Self.wakeCharUUID.uuidString, privacy: .public) not found on any service")
                finish(false)
            }
            return
        }
        // Fires once per service, so guard against a second pulse task racing
        // the first and disconnecting out from under it.
        guard !isPulsing else { return }
        isPulsing = true
        Task { await self.pulseAndDisconnect(characteristic: wakeCharacteristic, peripheral: peripheral) }
    }
}
