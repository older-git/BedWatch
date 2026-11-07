// Ports of decode_system() / decode_pinch() from ha_smartbed sleep_number_mcr_protocol.py.

/// Foundation capabilities (`0x42 FN=0x25`).
public struct FoundationSystem: Equatable, Sendable {
    public enum Generation: String, Sendable { case legacy, threeSixty = "360" }
    public enum Model: String, Sendable { case ff1 = "FF1", ff2 = "FF2", ff3 = "FF3" }

    public var configuration: UInt8
    public var hasFoot: Bool
    public var hasMassage: Bool
    public var hasWarming: Bool
    public var hasLight: Bool
    public var generation: Generation
    public var model: Model
    public var raw: [UInt8]

    /// Configuration 1 or 2 = split base with two articulating sides.
    public var sides: [MCRSide] { configuration == 1 || configuration == 2 ? [.right, .left] : [.right] }
    public var axes: [MCRAxis] { hasFoot ? [.head, .foot] : [.head] }

    public var presets: [MCRPreset] {
        var names: [MCRPreset] = [.favorite, .flat]
        if model != .ff1 {
            names += [.zeroG, .snore]
            if model == .ff3 { names += [.watchTV, .read] }
        } else if generation == .threeSixty {
            names.append(.snore)
        }
        return names
    }

    public init?(payload p: [UInt8]) {
        guard p.count >= 7 else { return nil }
        let flags = p[3]
        hasFoot = flags & 0x04 != 0
        hasMassage = flags & 0x02 != 0
        hasWarming = flags & 0x08 != 0
        hasLight = flags & 0x10 != 0
        if hasFoot && hasLight {
            generation = .threeSixty
            model = hasWarming ? .ff3 : .ff2
        } else if hasFoot {
            generation = .legacy
            model = hasMassage ? .ff3 : .ff2
        } else {
            generation = hasWarming || hasLight ? .threeSixty : .legacy
            model = .ff1
        }
        configuration = p[0] < 4 ? p[0] : 0
        raw = p
    }
}

/// Obstruction ("pinch") sensor status (`0x42 FN=0x28`), read only on 360 foundations.
public struct PinchStatus: Equatable, Sendable {
    public struct Sensor: Equatable, Sendable {
        public var disconnected: Bool
        public var continuous: Bool
        public var events: Int8
    }

    public var raw: [UInt8]

    public init?(payload: [UInt8]) {
        guard payload.count >= 5 else { return nil }
        raw = payload
    }

    public func sensor(_ axis: MCRAxis, side: MCRSide) -> Sensor {
        let (disconnected, continuous, index): (UInt8, UInt8, Int) = switch (axis, side) {
        case (.head, .right): (4, 64, 3)
        case (.head, .left): (8, 128, 4)
        case (.foot, .right): (1, 16, 1)
        case (.foot, .left): (2, 32, 2)
        }
        return Sensor(disconnected: raw[0] & disconnected != 0,
                      continuous: raw[0] & continuous != 0,
                      events: Int8(bitPattern: raw[index]))
    }
}
