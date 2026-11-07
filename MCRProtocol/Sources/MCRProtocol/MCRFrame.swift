// Sleep Number BAM / MCR wire framing.
// Port of SleepNumberMcrController._build_frame / _parse_frame / _extract_response_frames
// from kristofferR/ha_smartbed (custom_components/adjustable_bed/beds/sleep_number_mcr.py).
//
// Wire layout:
//   16 16 | CT | CA CA | SA SA | ST | CA CA | FN | SIDE<<4|LEN | payload | CRC(be16)
// CRC covers CT through end of payload.

public enum MCRNode: UInt8, Sendable {
    case pump = 0x02
    case discovery = 0x72
    case foundation = 0x42
    case sleepExpert = 0x52
}

public enum MCRSide: UInt8, Sendable {
    case right = 0
    case left = 1
}

public enum MCRError: Error, Equatable {
    case payloadTooLong(Int)
    case invalidValue(String)
}

public let mcrSync: [UInt8] = [0x16, 0x16]

/// Fletcher-style 16-bit checksum used by MCR frames.
public func mcrCRC<S: Sequence>(_ body: S) -> UInt16 where S.Element == UInt8 {
    var s = 0
    var r = 0
    for b in body {
        s += Int(b)
        r += s
    }
    return UInt16(truncatingIfNeeded: r)
}

public struct MCRFrame: Equatable, Sendable {
    public var commandType: UInt8
    /// Request: client address. Response: the address of the replying node (bed address at bind).
    public var target: UInt16
    public var subAddress: UInt16
    public var status: UInt8
    public var echo: UInt16
    /// Opcode with the response bit (0x80) stripped.
    public var functionCode: UInt8
    /// High nibble of the side/length byte (side, or a selector for some opcodes).
    public var side: UInt8
    public var payload: [UInt8]
    public var isResponse: Bool

    /// Encode a request frame. `status` defaults to `commandType`, matching ha_smartbed.
    public static func build(
        commandType: UInt8,
        status: UInt8? = nil,
        functionCode: UInt8,
        side: UInt8,
        payload: [UInt8] = [],
        subAddress: UInt16,
        clientAddress: UInt16 = 0
    ) throws -> [UInt8] {
        guard payload.count <= 15 else { throw MCRError.payloadTooLong(payload.count) }
        let caHi = UInt8(clientAddress >> 8), caLo = UInt8(clientAddress & 0xFF)
        var body: [UInt8] = [
            commandType,
            caHi, caLo,
            UInt8(subAddress >> 8), UInt8(subAddress & 0xFF),
            status ?? commandType,
            caHi, caLo,
            functionCode,
            ((side & 0x0F) << 4) | UInt8(payload.count),
        ]
        body += payload
        let crc = mcrCRC(body)
        return mcrSync + body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
    }

    /// Parse one complete frame. Returns nil on bad sync, CRC or length.
    public static func parse(_ data: [UInt8]) -> MCRFrame? {
        guard data.count >= 14, data[0] == 0x16, data[1] == 0x16 else { return nil }
        let body = Array(data[2..<(data.count - 2)])
        let expected = UInt16(data[data.count - 2]) << 8 | UInt16(data[data.count - 1])
        guard mcrCRC(body) == expected, body.count >= 10 else { return nil }
        let length = Int(body[9] & 0x0F)
        guard body.count >= 10 + length else { return nil }
        return MCRFrame(
            commandType: body[0],
            target: UInt16(body[1]) << 8 | UInt16(body[2]),
            subAddress: UInt16(body[3]) << 8 | UInt16(body[4]),
            status: body[5],
            echo: UInt16(body[6]) << 8 | UInt16(body[7]),
            functionCode: body[8] & 0x7F,
            side: body[9] >> 4,
            payload: Array(body[10..<(10 + length)]),
            isResponse: body[8] & 0x80 != 0
        )
    }
}

/// Reassembles frames from fragmented BLE notifications.
public struct MCRFrameAssembler: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Append a notification and return every complete, valid frame now available.
    /// Frames failing CRC are dropped, as in ha_smartbed.
    public mutating func append<C: Collection>(_ chunk: C) -> [MCRFrame] where C.Element == UInt8 {
        buffer += chunk
        var frames: [MCRFrame] = []
        while buffer.count >= 2 {
            guard let sync = firstSyncIndex() else {
                buffer.removeAll()
                break
            }
            if sync > 0 { buffer.removeFirst(sync) }
            guard buffer.count >= 12 else { break }
            let frameLength = 14 + Int(buffer[11] & 0x0F)
            guard buffer.count >= frameLength else { break }
            let raw = Array(buffer[..<frameLength])
            buffer.removeFirst(frameLength)
            if let frame = MCRFrame.parse(raw) { frames.append(frame) }
        }
        return frames
    }

    private func firstSyncIndex() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0..<(buffer.count - 1) where buffer[i] == 0x16 && buffer[i + 1] == 0x16 {
            return i
        }
        return nil
    }
}
