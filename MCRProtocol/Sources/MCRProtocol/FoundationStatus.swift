// Port of decode_foundation() from ha_smartbed sleep_number_mcr_protocol.py.

public struct FoundationStatus: Equatable, Sendable {
    public struct Actuator: Equatable, Sendable {
        public var position: UInt8
        public var flags: UInt8

        public var isMoving: Bool { flags & 0x01 != 0 }
        public var limitMissing: Bool { flags & 0x02 != 0 }
        public var limitUnexpected: Bool { flags & 0x04 != 0 }
        public var underCurrent: Bool { flags & 0x08 != 0 }
        public var overCurrent: Bool { flags & 0x10 != 0 }
        public var noMovement: Bool { flags & 0x20 != 0 }
        public var unexpectedMovement: Bool { flags & 0x40 != 0 }
        /// Any fault bit that ha_smartbed refuses to move with (0x02…0x40).
        public var hasFault: Bool { flags & 0x7E != 0 }
    }

    public var status: UInt8
    public var rightHead: Actuator
    public var leftHead: Actuator
    public var rightFoot: Actuator
    public var leftFoot: Actuator
    public var rightTimer: UInt16
    public var leftTimer: UInt16
    public var rightTimerPreset: MCRPreset?
    public var leftTimerPreset: MCRPreset?
    public var rightPreset: MCRPreset?
    public var leftPreset: MCRPreset?

    public var isMoving: Bool { status & 0x01 != 0 }
    public var needsHoming: Bool { status & 0x20 != 0 }
    public var isConfigured: Bool { status & 0x40 != 0 }

    /// True if any actuator on either side reports motion (what ha_smartbed polls on).
    public var anyActuatorMoving: Bool {
        [rightHead, leftHead, rightFoot, leftFoot].contains { $0.isMoving }
    }

    public func actuator(_ axis: MCRAxis, side: MCRSide) -> Actuator {
        switch (axis, side) {
        case (.head, .right): rightHead
        case (.head, .left): leftHead
        case (.foot, .right): rightFoot
        case (.foot, .left): leftFoot
        }
    }

    public func preset(side: MCRSide) -> MCRPreset? {
        side == .right ? rightPreset : leftPreset
    }

    public init?(payload p: [UInt8]) {
        guard p.count >= 15 else { return nil }
        status = p[0]
        rightHead = Actuator(position: p[1], flags: p[9])
        leftHead = Actuator(position: p[2], flags: p[10])
        rightFoot = Actuator(position: p[3], flags: p[11])
        leftFoot = Actuator(position: p[4], flags: p[12])
        rightTimer = UInt16(p[5]) | UInt16(p[6]) << 8
        leftTimer = UInt16(p[7]) | UInt16(p[8]) << 8
        rightTimerPreset = MCRPreset(rawValue: p[13] & 0x0F)
        leftTimerPreset = MCRPreset(rawValue: p[13] >> 4)
        rightPreset = MCRPreset(rawValue: p[14] & 0x0F)
        leftPreset = MCRPreset(rawValue: p[14] >> 4)
    }
}
