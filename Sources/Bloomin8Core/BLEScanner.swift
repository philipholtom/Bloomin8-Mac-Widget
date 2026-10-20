import CoreBluetooth
import Foundation

public struct DiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    /// Battery percentage, if the peripheral happens to advertise it in its
    /// manufacturer data. Most BLE advertisements don't include this — it
    /// normally requires connecting and reading the Battery Service (0x180F)
    /// — so this is nil far more often than not.
    public var batteryPercent: Int?
    public var lastSeen: Date
}

/// Continuously scans for nearby BLE peripherals and publishes them as a live
/// list, for a device-picker UI (as opposed to `BLEWaker`, which scans for
/// one specific named frame and then stops). Only peripherals advertising a
/// name are kept — nameless devices aren't something a person could pick out
/// of a list.
///
/// Scoped to BLOOMIN8 frames specifically: `scanForPeripherals(withServices:)`
/// is given the frame's own advertised service UUID (see `BLEWaker`'s
/// `wakeCharUUID` comment — 0xFFF0 is the service frames advertise for
/// discovery, distinct from 0xF000/0xF001 which is the wake target), so
/// CoreBluetooth filters out every other nearby Bluetooth device — headphones,
/// trackpads, speakers, etc. — before they ever reach `didDiscover`.
@MainActor
public final class BLEScanner: NSObject, ObservableObject {
    /// Matches the discovery service documented in `BLEWaker`.
    private static let frameServiceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")

    @Published public private(set) var devices: [DiscoveredDevice] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var permissionDenied = false

    private var centralManager: CBCentralManager?
    private var indexByID: [UUID: Int] = [:]

    public override init() {
        super.init()
    }

    public func start() {
        guard centralManager == nil else { return }
        devices = []
        indexByID = [:]
        permissionDenied = false
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    public func stop() {
        centralManager?.stopScan()
        centralManager = nil
        isScanning = false
    }

    private func upsert(id: UUID, name: String, rssi: Int) {
        if let index = indexByID[id] {
            devices[index].rssi = rssi
            devices[index].lastSeen = Date()
        } else {
            indexByID[id] = devices.count
            devices.append(DiscoveredDevice(id: id, name: name, rssi: rssi, batteryPercent: nil, lastSeen: Date()))
        }
    }
}

extension BLEScanner: @MainActor CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            permissionDenied = false
            isScanning = true
            central.scanForPeripherals(withServices: [Self.frameServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .unauthorized:
            permissionDenied = true
            isScanning = false
        default:
            isScanning = false
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name,
              !name.isEmpty else { return }
        upsert(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
    }
}
