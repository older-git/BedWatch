// Connection lifecycle and command queue for the Watch remote.
//
// - Connects on demand, holds the link `linkHold` after the last command, then disconnects
//   cleanly. A stale client silences the pump until it is power-cycled, so every exit path
//   disconnects.
// - Taps coalesce: pressing Head + three times while the bed is moving queues one move to
//   the final target rather than three moves.

import Foundation
import MCRBluetooth
import MCRProtocol
import Observation
import WatchKit

@MainActor @Observable
final class BedController {
    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case working(String)
        case failed(String)
    }

    static let positionStep = 10
    static let firmnessStep = 5
    static let linkHold: Duration = .seconds(30)

    private(set) var phase: Phase = .idle
    private(set) var status: FoundationStatus?
    private(set) var pump: PumpStatus?
    private(set) var system: FoundationSystem?
    private(set) var desiredPosition: [MCRAxis: UInt8] = [:]
    private(set) var desiredFirmness: [MCRSide: Int] = [:]
    private var queuedPreset: MCRPreset?

    private(set) var firmnessSide: MCRSide

    func selectFirmnessSide(_ side: MCRSide) {
        firmnessSide = side
        UserDefaults.standard.set(Int(side.rawValue), forKey: Keys.firmnessSide)
    }

    private let link: MCRBluetoothLink
    private var session: MCRSession?
    private var worker: Task<Void, Never>?
    private var idleDisconnect: Task<Void, Never>?

    init() {
        link = MCRBluetoothLink(log: { print("[bed] \($0)") })
        firmnessSide = MCRSide(rawValue: UInt8(UserDefaults.standard.integer(forKey: Keys.firmnessSide))) ?? .left
        link.onDisconnect = { [weak self] why in
            Task { @MainActor in self?.linkDropped(why) }
        }
    }

    var isBusy: Bool { worker != nil }
    var hasFoot: Bool { system?.hasFoot ?? true }
    private var baseSide: MCRSide { system?.sides.first ?? .right }

    func position(_ axis: MCRAxis) -> UInt8? {
        status?.actuator(axis, side: baseSide).position
    }

    func firmness(_ side: MCRSide) -> UInt8? {
        guard let pump else { return nil }
        return side == .left ? pump.left : pump.right
    }

    // MARK: Taps

    func nudge(_ axis: MCRAxis, up: Bool) {
        guard let current = desiredPosition[axis] ?? position(axis) else { return refresh() }
        let delta = up ? Self.positionStep : -Self.positionStep
        desiredPosition[axis] = UInt8(clamping: min(100, max(0, Int(current) + delta)))
        tap()
    }

    func nudgeFirmness(up: Bool) {
        let side = firmnessSide
        guard let current = desiredFirmness[side] ?? firmness(side).map(Int.init) else { return refresh() }
        let delta = up ? Self.firmnessStep : -Self.firmnessStep
        desiredFirmness[side] = snapFirmness(current + delta)
        tap()
    }

    func preset(_ preset: MCRPreset) {
        desiredPosition = [:]
        queuedPreset = preset
        tap()
    }

    /// Stop button: cancelling the worker makes the session send SE stop.
    func stop() {
        if cancelWork() { WKInterfaceDevice.current().play(.stop) }
    }

    /// Returns whether anything was actually running or queued.
    @discardableResult
    private func cancelWork() -> Bool {
        let hadWork = worker != nil || hasPendingJobs
        desiredPosition = [:]
        desiredFirmness = [:]
        queuedPreset = nil
        worker?.cancel()
        return hadWork
    }

    /// Connect (if needed) and read current values, without changing anything.
    func refresh() {
        guard worker == nil else { return }
        startWorker()
    }

    /// Silently stop any work and drop the link. Used when the app goes to the background
    /// (watchOS suspends it, which would leave the pump with a stale client) and when the
    /// weather page takes over. No haptic: here it would read as a notification.
    func release() {
        cancelWork()
        disconnect()
    }

    private func tap() {
        WKInterfaceDevice.current().play(.click)
        if worker == nil { startWorker() }
    }

    // MARK: Worker

    private func startWorker() {
        idleDisconnect?.cancel()
        worker = Task { [weak self] in
            // A tap can land after drain() found no job but before it returned; go round again.
            while let self {
                await self.drain()
                if Task.isCancelled || !self.hasPendingJobs { break }
            }
            self?.worker = nil
            self?.scheduleIdleDisconnect()
        }
    }

    private func drain() async {
        do {
            let (session, system) = try await connected()
            try await refreshValues(session)
            while !Task.isCancelled, let job = nextJob() {
                switch job {
                case .preset(let p):
                    phase = .working(p == .flat ? "Flat…" : "Favorite…")
                    status = try await session.preset(p, side: baseSide, system: system)
                case .position(let axis, let target):
                    phase = .working("\(axis == .head ? "Head" : "Foot") → \(target)%")
                    status = try await session.setPosition(axis, to: target, side: baseSide, system: system)
                    if desiredPosition[axis] == target { desiredPosition[axis] = nil }
                case .firmness(let side, let value):
                    phase = .working("\(side == .left ? "Left" : "Right") → \(value)")
                    pump = try await session.setFirmness(value, side: side)
                    if desiredFirmness[side] == value { desiredFirmness[side] = nil }
                }
                WKInterfaceDevice.current().play(.success)
            }
            if Task.isCancelled { try? await refreshValues(session) }
            phase = .ready
        } catch {
            desiredPosition = [:]
            desiredFirmness = [:]
            queuedPreset = nil
            if Task.isCancelled || error is CancellationError {
                // The session already sent SE stop; show where the bed actually ended up.
                if let session { try? await refreshValues(session) }
                phase = session == nil ? .idle : .ready
            } else {
                phase = .failed(message(for: error))
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    private var hasPendingJobs: Bool {
        queuedPreset != nil || !desiredPosition.isEmpty || !desiredFirmness.isEmpty
    }

    private enum Job {
        case preset(MCRPreset)
        case position(MCRAxis, UInt8)
        case firmness(MCRSide, Int)
    }

    private func nextJob() -> Job? {
        if let p = queuedPreset {
            queuedPreset = nil
            return .preset(p)
        }
        for axis in [MCRAxis.head, .foot] {
            guard let target = desiredPosition[axis] else { continue }
            if let now = position(axis), abs(Int(now) - Int(target)) < 3 {
                desiredPosition[axis] = nil
                continue
            }
            return .position(axis, target)
        }
        for side in [MCRSide.left, .right] {
            guard let value = desiredFirmness[side] else { continue }
            if firmness(side).map(Int.init) == value {
                desiredFirmness[side] = nil
                continue
            }
            return .firmness(side, value)
        }
        return nil
    }

    private func refreshValues(_ session: MCRSession) async throws {
        status = try await session.foundationStatus()
        pump = try await session.pumpStatus()
    }

    // MARK: Connection

    private func connected() async throws -> (MCRSession, FoundationSystem) {
        if let session, let system, link.isConnected { return (session, system) }
        phase = .connecting
        let saved = UserDefaults.standard.string(forKey: Keys.peripheral).flatMap(UUID.init(uuidString:))
        do {
            try await link.connect(identifier: saved, scanTimeout: .seconds(20))
        } catch where saved != nil {
            // Cached ID can go stale (e.g. after re-pairing); fall back to a service scan.
            try await link.connect(identifier: nil, scanTimeout: .seconds(20))
        }
        if let id = link.peripheralIdentifier {
            UserDefaults.standard.set(id.uuidString, forKey: Keys.peripheral)
        }
        let session = MCRSession(link: link, log: { print("[bed] \($0)") })
        do {
            _ = try await session.bind(clientID: Self.clientID())
            let system = try await session.foundationSystem()
            self.session = session
            self.system = system
            phase = .ready
            return (session, system)
        } catch {
            link.disconnect()
            throw error
        }
    }

    private func scheduleIdleDisconnect() {
        idleDisconnect?.cancel()
        idleDisconnect = Task { [weak self] in
            try? await Task.sleep(for: Self.linkHold)
            guard !Task.isCancelled else { return }
            self?.disconnect()
        }
    }

    private func disconnect() {
        idleDisconnect?.cancel()
        link.disconnect()
        session = nil
        if case .failed = phase {} else { phase = .idle }
    }

    private func linkDropped(_ why: String) {
        session = nil
        if case .failed = phase {} else { phase = .idle }
    }

    private func message(for error: Error) -> String {
        switch error {
        case let e as MCRSessionError: e.description
        case let e as MCRBluetoothError: e.description
        default: "\(error)"
        }
    }

    private enum Keys {
        static let clientID = "mcrClientID"
        static let peripheral = "mcrPeripheral"
        static let firmnessSide = "firmnessSide"
    }

    /// Random nonzero 64-bit client ID, persisted so the pump sees the same client every time.
    private static func clientID() -> UInt64 {
        if let text = UserDefaults.standard.string(forKey: Keys.clientID),
           let id = UInt64(text, radix: 16), id != 0 {
            return id
        }
        var id: UInt64 = 0
        while id == 0 { id = UInt64.random(in: .min ... .max) }
        UserDefaults.standard.set(String(id, radix: 16), forKey: Keys.clientID)
        return id
    }
}
