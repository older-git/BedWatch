// CoreBluetooth central for the Sleep Number MCR transport. Shared by bedctl (macOS) and the
// Watch app. All CoreBluetooth state lives on `queue`.

@preconcurrency import CoreBluetooth
import Foundation
import MCRProtocol

public enum MCRBluetoothError: Error, CustomStringConvertible {
    case unavailable(CBManagerState)
    case timedOut(String)
    case disconnected(String)
    case missingCharacteristic
    case gatt(String)

    public var description: String {
        switch self {
        case .unavailable(let state):
            "Bluetooth unavailable (state \(state.rawValue); 3 = unauthorized: allow Bluetooth for this terminal in System Settings → Privacy & Security)"
        case .timedOut(let what): "Timed out: \(what)"
        case .disconnected(let why): "Disconnected: \(why)"
        case .missingCharacteristic: "MCR service is missing its notify/write characteristics"
        case .gatt(let why): "GATT error: \(why)"
        }
    }
}

public final class MCRBluetoothLink: NSObject, MCRLink, @unchecked Sendable {
    public static let serviceUUID = CBUUID(string: "ffffd1fd-388d-938b-344a-939d1f6efee0")
    public static let notifyUUID = CBUUID(string: "ffffd1fd-388d-938b-344a-939d1f6efee1")
    public static let writeUUID = CBUUID(string: "ffffd1fd-388d-938b-344a-939d1f6efee2")

    private let queue = DispatchQueue(label: "mcr.bluetooth")
    private let log: @Sendable (String) -> Void

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?

    // One sequential GATT step (power on, scan, connect, discover, subscribe, write) at a time.
    private var stepID: UInt64 = 0
    private var stepContinuation: CheckedContinuation<Void, Error>?

    // Response wait for the in-flight exchange.
    private var assembler = MCRFrameAssembler()
    private var responseMatcher: (@Sendable (MCRFrame) -> Bool)?
    private var matchedFrame: MCRFrame?
    private var responseID: UInt64 = 0
    private var responseContinuation: CheckedContinuation<MCRFrame, Error>?

    public private(set) var peripheralName: String?
    public private(set) var peripheralIdentifier: UUID?
    public var isConnected: Bool { onQueue { connected } }
    private var connected = false

    /// Called on the link's queue when an established connection drops (including by request).
    public var onDisconnect: (@Sendable (String) -> Void)?

    /// One advertising device seen by `survey`.
    public struct Sighting: Sendable {
        public var identifier: UUID
        public var name: String?
        public var rssi: Int
        public var services: [String]
        public var manufacturerData: [UInt8]?
        public var connectable: Bool?
    }

    // Survey mode: record every advertisement instead of connecting.
    private var surveying = false
    private var sightings: [UUID: Sighting] = [:]

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    // MARK: Connect / disconnect

    private func powerOn() async throws {
        try await step("Bluetooth power-on", timeout: .seconds(10)) {
            if let central = self.central, central.state == .poweredOn {
                self.finishStep(.success(()))
            } else if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
    }

    /// Unfiltered scan: every advertising device, strongest first.
    public func survey(duration: Duration = .seconds(10)) async throws -> [Sighting] {
        try await powerOn()
        onQueue {
            self.surveying = true
            self.sightings = [:]
            self.central!.scanForPeripherals(withServices: nil,
                                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        try await Task.sleep(for: duration)
        return onQueue {
            self.central!.stopScan()
            self.surveying = false
            return self.sightings.values.sorted { $0.rssi > $1.rssi }
        }
    }

    /// Connect to the pump. With `identifier`, connect to that CoreBluetooth peripheral directly
    /// (for pumps that don't advertise the MCR service UUID); otherwise scan for the service UUID.
    public func connect(identifier: UUID? = nil, scanTimeout: Duration = .seconds(120)) async throws {
        try await powerOn()
        log(identifier == nil ? "scanning for MCR service…" : "looking up \(identifier!)…")
        try await step("scan for MCR pump", timeout: scanTimeout) {
            let central = self.central!
            self.peripheral = nil
            self.connected = false
            if let identifier {
                guard let known = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                    return self.finishStep(.failure(MCRBluetoothError.timedOut("no peripheral \(identifier); run bedctl scan")))
                }
                self.adopt(known)
                self.finishStep(.success(()))
            } else if let known = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
                self.log("using already-connected peripheral \(known.name ?? "?")")
                self.adopt(known)
                self.finishStep(.success(()))
            } else {
                central.scanForPeripherals(withServices: [Self.serviceUUID])
            }
        }
        do {
            log("connecting…")
            try await step("connect", timeout: .seconds(30)) {
                self.central!.connect(self.peripheral!)
            }
            log("connected; discovering services…")
            try await step("discover services", timeout: .seconds(10)) {
                self.peripheral!.discoverServices([Self.serviceUUID])
            }
            // ha_smartbed waits 128 ms after discovery before enabling notifications.
            try await Task.sleep(for: .milliseconds(128))
            try await step("enable notifications", timeout: .seconds(5)) {
                self.peripheral!.setNotifyValue(true, for: self.notifyChar!)
            }
        } catch {
            // Never leave a half-open link: a stale client silences the pump until power-cycled.
            disconnect()
            throw error
        }
        let mtu = onQueue { () -> Int in
            self.connected = true
            return self.peripheral!.maximumWriteValueLength(for: .withResponse)
        }
        log("connected; write chunk size \(mtu)")
    }

    public func disconnect() {
        queue.sync {
            if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        }
    }

    // MARK: MCRLink

    public func exchange(
        _ frame: [UInt8], timeout: Duration, matching: @escaping @Sendable (MCRFrame) -> Bool
    ) async throws -> MCRFrame {
        onQueue {
            self.assembler = MCRFrameAssembler()
            self.matchedFrame = nil
            self.responseMatcher = matching
        }
        defer { onQueue { self.responseMatcher = nil } }

        log("TX \(hex(frame))")
        try await write(frame)
        return try await waitForResponse(timeout: timeout, functionCode: frame.count > 10 ? frame[10] : 0)
    }

    private func write(_ frame: [UInt8]) async throws {
        let (chunkSize, properties) = try onQueue { () throws -> (Int, CBCharacteristicProperties) in
            guard let peripheral = self.peripheral, let writeChar = self.writeChar else {
                throw MCRBluetoothError.missingCharacteristic
            }
            return (max(1, peripheral.maximumWriteValueLength(for: .withResponse)), writeChar.properties)
        }
        var offset = 0
        while offset < frame.count {
            let chunk = Data(frame[offset..<min(offset + chunkSize, frame.count)])
            offset += chunkSize
            if properties.contains(.write) {
                do {
                    try await step("write", timeout: .seconds(3)) {
                        self.peripheral!.writeValue(chunk, for: self.writeChar!, type: .withResponse)
                    }
                    continue
                } catch {
                    guard properties.contains(.writeWithoutResponse) else { throw error }
                    log("write with response failed (\(error)); retrying without response")
                }
            }
            onQueue { self.peripheral!.writeValue(chunk, for: self.writeChar!, type: .withoutResponse) }
        }
    }

    private func waitForResponse(timeout: Duration, functionCode: UInt8) async throws -> MCRFrame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MCRFrame, Error>) in
            queue.async {
                if let frame = self.matchedFrame {
                    cont.resume(returning: frame)
                    return
                }
                self.responseID &+= 1
                let id = self.responseID
                self.responseContinuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout.seconds) {
                    guard self.responseID == id, let cont = self.responseContinuation else { return }
                    self.responseContinuation = nil
                    cont.resume(throwing: MCRResponseTimeout(functionCode: functionCode))
                }
            }
        }
    }

    // MARK: Step plumbing

    private func step(_ name: String, timeout: Duration, _ start: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.stepID &+= 1
                let id = self.stepID
                self.stepContinuation = cont
                start()
                self.queue.asyncAfter(deadline: .now() + timeout.seconds) {
                    guard self.stepID == id, self.stepContinuation != nil else { return }
                    if name.hasPrefix("scan") { self.central?.stopScan() }
                    self.finishStep(.failure(MCRBluetoothError.timedOut(name)))
                }
            }
        }
    }

    private func finishStep(_ result: Result<Void, Error>) {
        guard let cont = stepContinuation else { return }
        stepContinuation = nil
        cont.resume(with: result)
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        peripheralIdentifier = p.identifier
        peripheralName = p.name
        p.delegate = self
    }
}

extension MCRBluetoothLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state \(central.state.rawValue), authorization \(CBManager.authorization.rawValue)")
        switch central.state {
        case .poweredOn: finishStep(.success(()))
        case .unknown, .resetting: break
        default: finishStep(.failure(MCRBluetoothError.unavailable(central.state)))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if surveying {
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
                + (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
            var sighting = sightings[peripheral.identifier] ?? Sighting(
                identifier: peripheral.identifier, name: nil, rssi: RSSI.intValue, services: [],
                manufacturerData: nil, connectable: nil)
            sighting.name = name ?? sighting.name
            sighting.rssi = max(sighting.rssi, RSSI.intValue)
            sighting.services = Array(Set(sighting.services + uuids.map(\.uuidString))).sorted()
            if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                sighting.manufacturerData = Array(data)
            }
            sighting.connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? sighting.connectable
            sightings[peripheral.identifier] = sighting
            return
        }
        guard self.peripheral == nil else { return }
        central.stopScan()
        log("found \(peripheral.name ?? "?") \(peripheral.identifier) RSSI \(RSSI)")
        adopt(peripheral)
        finishStep(.success(()))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        finishStep(.success(()))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishStep(.failure(MCRBluetoothError.gatt("connect failed: \(error.map { "\($0)" } ?? "unknown")")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        let why = error.map { "\($0.localizedDescription)" } ?? "by request"
        log("disconnected: \(why)")
        notifyChar = nil
        writeChar = nil
        let wasConnected = connected
        connected = false
        finishStep(.failure(MCRBluetoothError.disconnected(why)))
        if wasConnected { onDisconnect?(why) }
        if let cont = responseContinuation {
            responseContinuation = nil
            cont.resume(throwing: MCRBluetoothError.disconnected(why))
        }
    }
}

extension MCRBluetoothLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return finishStep(.failure(MCRBluetoothError.gatt("\(error)"))) }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            return finishStep(.failure(MCRBluetoothError.missingCharacteristic))
        }
        peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error { return finishStep(.failure(MCRBluetoothError.gatt("\(error)"))) }
        notifyChar = service.characteristics?.first { $0.uuid == Self.notifyUUID }
        writeChar = service.characteristics?.first { $0.uuid == Self.writeUUID }
        guard notifyChar != nil, writeChar != nil else {
            return finishStep(.failure(MCRBluetoothError.missingCharacteristic))
        }
        finishStep(.success(()))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        finishStep(error.map { .failure(MCRBluetoothError.gatt("notify: \($0)")) } ?? .success(()))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        finishStep(error.map { .failure(MCRBluetoothError.gatt("write: \($0)")) } ?? .success(()))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.notifyUUID, let data = characteristic.value else { return }
        log("RX \(hex(Array(data)))")
        for frame in assembler.append(data) {
            if let matcher = responseMatcher, matchedFrame == nil, matcher(frame) {
                matchedFrame = frame
                if let cont = responseContinuation {
                    responseContinuation = nil
                    cont.resume(returning: frame)
                }
            } else {
                log("  unmatched frame: ct=0x\(String(frame.commandType, radix: 16)) fn=0x\(String(frame.functionCode, radix: 16)) side=\(frame.side) target=0x\(String(frame.target, radix: 16)) sa=0x\(String(frame.subAddress, radix: 16)) echo=0x\(String(frame.echo, radix: 16)) resp=\(frame.isResponse)")
            }
        }
    }
}

public func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

extension Duration {
    fileprivate var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}
