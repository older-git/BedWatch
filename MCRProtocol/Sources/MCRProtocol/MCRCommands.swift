// Watch-remote subset of MCR requests. Opcodes and payloads follow ha_smartbed; none of this
// is hardware-validated yet.

public struct MCRRequest: Equatable, Sendable {
    public var node: MCRNode
    public var functionCode: UInt8
    /// Side, or selector for opcodes that overload the nibble (e.g. foundation status).
    public var side: UInt8
    public var payload: [UInt8]

    public init(node: MCRNode, functionCode: UInt8, side: UInt8 = 0, payload: [UInt8] = []) {
        self.node = node
        self.functionCode = functionCode
        self.side = side
        self.payload = payload
    }

    /// Encode with the addresses negotiated at bind.
    public func encode(clientAddress: UInt16, bedAddress: UInt16) throws -> [UInt8] {
        try MCRFrame.build(
            commandType: node.rawValue,
            functionCode: functionCode,
            side: side,
            payload: payload,
            subAddress: bedAddress,
            clientAddress: clientAddress
        )
    }
}

public enum MCRPreset: UInt8, Sendable {
    case favorite = 1, read = 2, watchTV = 3, flat = 4, zeroG = 5, snore = 6
}

public enum MCRAxis: Sendable {
    case head, foot
}

extension MCRRequest {
    // MARK: Session

    /// Bind is always sent with zero addresses; see `MCRBinding`.
    public static func bind(clientID: UInt64) -> MCRRequest {
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: clientID >> (56 - 8 * $0)) }
        return MCRRequest(node: .pump, functionCode: 0x00, payload: bytes)
    }

    // MARK: Pump / firmness

    public static let pumpForceIdle = MCRRequest(node: .pump, functionCode: 0x02)
    public static let pumpStatus = MCRRequest(node: .pump, functionCode: 0x12)
    public static let firmnessFavorites = MCRRequest(node: .pump, functionCode: 0x14)

    /// Firmness 5–100, snapped to the nearest multiple of 5. Send `pumpForceIdle` first.
    public static func setFirmness(_ value: Int, side: MCRSide) -> MCRRequest {
        MCRRequest(node: .pump, functionCode: 0x11, side: side.rawValue,
                   payload: [0x00, UInt8(snapFirmness(value))])
    }

    public static func saveFirmnessFavorite(_ value: Int, side: MCRSide) -> MCRRequest {
        MCRRequest(node: .pump, functionCode: 0x13, side: side.rawValue,
                   payload: [UInt8(snapFirmness(value))])
    }

    // MARK: Foundation

    /// Plain status read, or with `keepAdjusting` the side-specific selector (side + 2) used while
    /// a microadjust is held.
    public static func foundationStatus(keepAdjusting side: MCRSide? = nil) -> MCRRequest {
        MCRRequest(node: .foundation, functionCode: 0x12, side: side.map { $0.rawValue + 2 } ?? 0)
    }

    /// Microadjust toward `target` %. In ha_smartbed this is a *held* motion: it is kept alive by
    /// `foundationStatus(keepAdjusting:)` polls and ended with `stop(side:)`.
    public static func microadjust(_ axis: MCRAxis, to target: UInt8, side: MCRSide) throws -> MCRRequest {
        guard target <= 100 else { throw MCRError.invalidValue("position \(target)") }
        var payload = [UInt8](repeating: 0xFF, count: 12)
        let offset = axis == .head ? 0 : 2
        payload[offset] = target
        payload[offset + 1] = 0x00
        return MCRRequest(node: .foundation, functionCode: 0x11, side: side.rawValue, payload: payload)
    }

    public static func preset(_ preset: MCRPreset, side: MCRSide) -> MCRRequest {
        MCRRequest(node: .foundation, functionCode: 0x15, side: side.rawValue, payload: [preset.rawValue, 0x00])
    }

    public static func saveFavoritePosition(side: MCRSide) -> MCRRequest {
        MCRRequest(node: .foundation, functionCode: 0x16, side: side.rawValue, payload: [MCRPreset.favorite.rawValue])
    }

    // MARK: Sleep Expert (key/value) — used by ha_smartbed for stop and absolute positions

    public static func seWrite(key: String, value: [UInt8]) throws -> MCRRequest {
        let keyBytes = Array(key.utf8)
        guard keyBytes.count == 4, value.count <= 11 else {
            throw MCRError.invalidValue("SE key \(key) / \(value.count) bytes")
        }
        return MCRRequest(node: .sleepExpert, functionCode: 0x1B, payload: keyBytes + value)
    }

    /// Stop foundation motion on one side (`MFHR`/`MFHL` = "110").
    public static func stop(side: MCRSide) -> MCRRequest {
        try! seWrite(key: side == .left ? "MFHL" : "MFHR", value: Array("110".utf8))
    }

    /// Absolute position: the bed drives to `position` % and stops (keys MFU*/MFF*, value "N_0").
    public static func setPosition(_ axis: MCRAxis, to position: UInt8, side: MCRSide) throws -> MCRRequest {
        guard position <= 100 else { throw MCRError.invalidValue("position \(position)") }
        let key = (axis == .head ? "MFU" : "MFF") + (side == .left ? "L" : "R")
        return try seWrite(key: key, value: Array("\(position)_0".utf8))
    }
}

/// Clamp to 5…100 and round to a multiple of 5. Python's `round()` is banker's rounding, so ties
/// (x2.5, x7.5) only occur for non-integers; integer inputs never tie, and this matches.
public func snapFirmness(_ value: Int) -> Int {
    let clamped = max(5, min(100, value))
    return Int((Double(clamped) / 5).rounded()) * 5
}

/// Addresses assigned by the bind reply.
public struct MCRBinding: Equatable, Sendable {
    public var clientAddress: UInt16
    public var bedAddress: UInt16

    public init(clientAddress: UInt16, bedAddress: UInt16) {
        self.clientAddress = clientAddress
        self.bedAddress = bedAddress
    }

    /// Accepts the first reply frame whose payload is ≥ 10 bytes.
    public init?(replies: [MCRFrame]) {
        guard let frame = replies.first(where: { $0.payload.count >= 10 }) else { return nil }
        clientAddress = UInt16(frame.payload[8]) << 8 | UInt16(frame.payload[9])
        bedAddress = frame.target
    }
}
