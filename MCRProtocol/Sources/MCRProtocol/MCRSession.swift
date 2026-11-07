// Session logic: bind, response correlation, retries and the foundation motion flow.
// Mirrors SleepNumberMcrController in ha_smartbed; transport-agnostic so it runs over
// CoreBluetooth on the Watch/Mac or a fake link in tests.

/// Sends one encoded frame and returns the first notification frame `matching` accepts.
public protocol MCRLink: Sendable {
    func exchange(
        _ frame: [UInt8], timeout: Duration, matching: @escaping @Sendable (MCRFrame) -> Bool
    ) async throws -> MCRFrame
}

public struct MCRResponseTimeout: Error, Equatable {
    public var functionCode: UInt8
    public init(functionCode: UInt8) { self.functionCode = functionCode }
}

public enum MCRSessionError: Error, Equatable, CustomStringConvertible {
    case notBound
    case bindRejected
    case seRejected
    case badPayload(String)
    case foundation(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .notBound: "Not bound to the bed"
        case .bindRejected: "Bind reply omitted assigned addresses"
        case .seRejected: "Sleep Expert rejected the request"
        case .badPayload(let what): "Unexpected payload: \(what)"
        case .foundation(let what): what
        case .timedOut(let what): "Timed out: \(what)"
        }
    }
}

public struct PumpStatus: Equatable, Sendable {
    public var adjusting: Bool
    public var dualChamber: Bool
    public var left: UInt8
    public var right: UInt8
}

public actor MCRSession {
    public static let foundationTimeout: Duration = .seconds(120)

    private let link: any MCRLink
    private let log: @Sendable (String) -> Void
    public private(set) var binding: MCRBinding?

    public init(link: any MCRLink, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.link = link
        self.log = log
    }

    // MARK: Transport

    func setBindingForTesting(_ binding: MCRBinding) { self.binding = binding }

    public func bind(clientID: UInt64) async throws -> MCRBinding {
        precondition(clientID != 0, "client ID must be nonzero")
        binding = nil
        let frame = try MCRRequest.bind(clientID: clientID).encode(clientAddress: 0, bedAddress: 0)
        let reply = try await send(frame, functionCode: 0x00, node: .pump, timeout: .milliseconds(900),
                                   match: Self.matcher(node: .pump, functionCode: 0x00, binding: nil))
        guard let result = MCRBinding(replies: [reply]) else { throw MCRSessionError.bindRejected }
        binding = result
        return result
    }

    /// Send a request and return the reply frame, retrying a missing reply three times.
    @discardableResult
    public func request(_ r: MCRRequest, timeout: Duration = .milliseconds(900)) async throws -> MCRFrame {
        guard let binding else { throw MCRSessionError.notBound }
        let frame = try r.encode(clientAddress: binding.clientAddress, bedAddress: binding.bedAddress)
        let reply = try await send(frame, functionCode: r.functionCode, node: r.node, timeout: timeout,
                                   match: Self.matcher(node: r.node, functionCode: r.functionCode, binding: binding))
        if r.node == .sleepExpert && reply.side == 0x0F { throw MCRSessionError.seRejected }
        return reply
    }

    private func send(
        _ frame: [UInt8], functionCode: UInt8, node: MCRNode, timeout: Duration,
        match: @escaping @Sendable (MCRFrame) -> Bool
    ) async throws -> MCRFrame {
        for attempt in 0..<4 {
            do {
                return try await link.exchange(frame, timeout: timeout, matching: match)
            } catch is MCRResponseTimeout where attempt < 3 {
                log("no reply to fn=0x\(String(functionCode, radix: 16)) (attempt \(attempt + 1)/4), retrying")
            } catch is MCRResponseTimeout {
                throw MCRSessionError.timedOut("node 0x\(String(node.rawValue, radix: 16)) fn=0x\(String(functionCode, radix: 16))")
            }
        }
        fatalError("unreachable")
    }

    /// ha_smartbed `_frame_matches_request_key`: the reply carries our client address in its SA slot
    /// and, once bound, the bed address in its echo slot.
    static func matcher(node: MCRNode, functionCode: UInt8, binding: MCRBinding?) -> @Sendable (MCRFrame) -> Bool {
        let client = binding?.clientAddress ?? 0
        let bed = binding?.bedAddress ?? 0
        return { f in
            guard f.isResponse, f.commandType & 0xF0 == node.rawValue & 0xF0,
                  f.subAddress == client, f.functionCode == functionCode else { return false }
            return f.subAddress == 0 || f.echo == bed
        }
    }

    // MARK: Reads

    public func nodes() async throws -> [UInt8] {
        try await request(MCRRequest(node: .discovery, functionCode: 0x12)).payload
    }

    public func pumpStatus() async throws -> PumpStatus {
        let f = try await request(.pumpStatus)
        guard f.payload.count >= 3 else { throw MCRSessionError.badPayload("pump status \(f.payload)") }
        // Hardware-confirmed: [1] = right, [2] = left. ha_smartbed has these swapped
        // (setting side 1 = left changed byte [2], and the remote showed left 55).
        return PumpStatus(adjusting: f.payload[0] != 0, dualChamber: f.side == 1,
                          left: f.payload[2], right: f.payload[1])
    }

    public func foundationSystem() async throws -> FoundationSystem {
        let p = try await request(MCRRequest(node: .foundation, functionCode: 0x25)).payload
        guard let s = FoundationSystem(payload: p) else { throw MCRSessionError.badPayload("system \(p)") }
        return s
    }

    public func foundationStatus(keepAdjusting side: MCRSide? = nil) async throws -> FoundationStatus {
        let p = try await request(.foundationStatus(keepAdjusting: side)).payload
        guard let s = FoundationStatus(payload: p) else { throw MCRSessionError.badPayload("foundation \(p)") }
        return s
    }

    public func pinchStatus() async throws -> PinchStatus {
        let p = try await request(MCRRequest(node: .foundation, functionCode: 0x28)).payload
        guard let s = PinchStatus(payload: p) else { throw MCRSessionError.badPayload("pinch \(p)") }
        return s
    }

    // MARK: Firmness

    /// Force the pump idle, then set one side's firmness (5–100, snapped to 5). With
    /// `waitUntilDone`, poll pump status every second until it stops adjusting.
    /// On any failure the pump is forced idle again, as in ha_smartbed.
    public func setFirmness(_ value: Int, side: MCRSide, waitUntilDone: Bool = true,
                            timeout: Duration = .seconds(120)) async throws -> PumpStatus {
        try await request(.pumpForceIdle)
        do {
            try await request(.setFirmness(value, side: side))
            guard waitUntilDone else { return try await pumpStatus() }
            let deadline = ContinuousClock.now + timeout
            while true {
                try await Task.sleep(for: .seconds(1))
                let pump = try await pumpStatus()
                log("pump: L \(pump.left) R \(pump.right) adjusting \(pump.adjusting)")
                if !pump.adjusting { return pump }
                guard ContinuousClock.now < deadline else { throw MCRSessionError.timedOut("pump adjustment") }
            }
        } catch {
            log("firmness failed (\(error)); forcing pump idle")
            do { try await idlePump() } catch { log("pump cleanup failed: \(error)") }
            throw error
        }
    }

    /// ha_smartbed `_idle_pump_after_cancel`: force idle, then poll until the pump reports inactive.
    public func idlePump(timeout: Duration = .seconds(10)) async throws {
        try await request(.pumpForceIdle)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if try await !pumpStatus().adjusting { return }
        }
        throw MCRSessionError.timedOut("Could not confirm the pump stopped")
    }

    // MARK: Foundation motion

    public func stop(side: MCRSide) async throws {
        try await request(.stop(side: side))
    }

    /// Run a preset on one side and confirm it took effect. Flat doubles as homing recovery.
    public func preset(_ preset: MCRPreset, side: MCRSide, system: FoundationSystem) async throws -> FoundationStatus {
        let recovery = preset == .flat
        let targets = recovery ? system.axes.map { ($0, UInt8(0)) } : []
        return try await motion(side: side, system: system, allowHoming: recovery) {
            try await self.request(.preset(preset, side: side))
            return try await self.waitForFoundation(side: side, system: system, targets: targets,
                                                    allowHoming: recovery,
                                                    expectedPreset: recovery ? nil : preset)
        }
    }

    /// Drive one axis to an absolute position via the SE write and confirm it arrived.
    public func setPosition(_ axis: MCRAxis, to position: UInt8, side: MCRSide,
                            system: FoundationSystem) async throws -> FoundationStatus {
        guard system.axes.contains(axis) else { throw MCRSessionError.foundation("Foundation has no \(axis) motor") }
        return try await motion(side: side, system: system, allowHoming: false) {
            try await self.request(.setPosition(axis, to: position, side: side))
            return try await self.waitForFoundation(side: side, system: system, targets: [(axis, position)],
                                                    allowHoming: false, expectedPreset: nil)
        }
    }

    /// Pre-check, run `body`, then always release with SE stop and a final status read.
    private func motion(
        side: MCRSide, system: FoundationSystem, allowHoming: Bool,
        _ body: () async throws -> FoundationStatus
    ) async throws -> FoundationStatus {
        guard system.sides.contains(side) else { throw MCRSessionError.foundation("Foundation has no \(side) side") }
        let before = try await foundationStatus()
        log("before: \(describe(before))")
        try check(before, side: side, system: system, allowHoming: allowHoming)
        let pinchBefore = system.generation == .threeSixty ? try await checkPinch(side: side, system: system, previous: nil) : nil

        do {
            _ = try await body()
            if pinchBefore != nil { _ = try await checkPinch(side: side, system: system, previous: pinchBefore) }
        } catch {
            log("motion failed (\(error)); releasing")
            do { _ = try await release(side: side, system: system) } catch { log("cleanup failed: \(error)") }
            throw error
        }
        return try await release(side: side, system: system)
    }

    private func release(side: MCRSide, system: FoundationSystem) async throws -> FoundationStatus {
        try await stop(side: side)
        let final = try await foundationStatus()
        log("final: \(describe(final))")
        try check(final, side: side, system: system, allowHoming: false)
        return final
    }

    private func waitForFoundation(
        side: MCRSide, system: FoundationSystem, targets: [(MCRAxis, UInt8)],
        allowHoming: Bool, expectedPreset: MCRPreset?
    ) async throws -> FoundationStatus {
        let deadline = ContinuousClock.now + Self.foundationTimeout
        try await Task.sleep(for: .seconds(1))
        var stationary = 0
        while true {
            guard ContinuousClock.now < deadline else { throw MCRSessionError.timedOut("foundation motion") }
            let s = try await foundationStatus()
            log("poll: \(describe(s))")
            try check(s, side: side, system: system, allowHoming: allowHoming)
            let moving = s.anyActuatorMoving
            stationary = moving ? 0 : stationary + 1
            // Confirm an initial stationary reply with two more samples.
            if stationary == 3 {
                try check(s, side: side, system: system, allowHoming: false)
                if let expectedPreset, s.preset(side: side) != expectedPreset {
                    throw MCRSessionError.foundation("Foundation stopped without confirming \(side) preset \(expectedPreset)")
                }
                for (axis, target) in targets {
                    let actual = s.actuator(axis, side: side).position
                    if abs(Int(actual) - Int(target)) >= 3 {
                        throw MCRSessionError.foundation("Stopped before reaching \(side) \(axis) target \(target): \(actual)")
                    }
                }
                return s
            }
            try await Task.sleep(for: moving ? .milliseconds(333) : .milliseconds(500))
        }
    }

    private func check(_ s: FoundationStatus, side: MCRSide, system: FoundationSystem, allowHoming: Bool) throws {
        guard s.isConfigured else { throw MCRSessionError.foundation("Foundation is not configured") }
        for axis in system.axes {
            let a = s.actuator(axis, side: side)
            if a.hasFault {
                throw MCRSessionError.foundation("Foundation \(side) \(axis) fault flags 0x\(String(a.flags, radix: 16))")
            }
        }
        if s.needsHoming && !allowHoming {
            throw MCRSessionError.foundation("Foundation needs homing; use Flat to recover")
        }
    }

    private func checkPinch(side: MCRSide, system: FoundationSystem, previous: PinchStatus?) async throws -> PinchStatus {
        let p = try await pinchStatus()
        for axis in system.axes {
            let sensor = p.sensor(axis, side: side)
            if sensor.disconnected || sensor.continuous {
                throw MCRSessionError.foundation("\(side) \(axis): obstruction sensor fault")
            }
        }
        // A non-split foundation compares obstruction events on both sides.
        let eventSides: [MCRSide] = system.sides.count == 2 ? [side] : [.right, .left]
        if let previous {
            for s in eventSides {
                for axis in system.axes where p.sensor(axis, side: s).events != previous.sensor(axis, side: s).events {
                    throw MCRSessionError.foundation("\(s) \(axis): obstruction counter changed during movement")
                }
            }
        }
        return p
    }
}

public func describe(_ s: FoundationStatus) -> String {
    func a(_ x: FoundationStatus.Actuator) -> String { "\(x.position)%\(x.isMoving ? "*" : "")" }
    return "head R \(a(s.rightHead)) L \(a(s.leftHead)) | foot R \(a(s.rightFoot)) L \(a(s.leftFoot))"
        + " | preset R \(s.rightPreset.map { "\($0)" } ?? "-") L \(s.leftPreset.map { "\($0)" } ?? "-")"
        + "\(s.needsHoming ? " | NEEDS HOMING" : "")\(s.isConfigured ? "" : " | UNCONFIGURED")"
}
