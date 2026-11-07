// Session flow against a scripted fake bed (no hardware).

import Testing
@testable import MCRProtocol

private final class FakeBed: MCRLink, @unchecked Sendable {
    let bed: UInt16 = 0x5678
    let client: UInt16 = 0x1234
    var statuses: [[UInt8]]
    var sent: [MCRFrame] = []

    init(statuses: [[UInt8]]) { self.statuses = statuses }

    func exchange(_ frame: [UInt8], timeout: Duration,
                  matching: @escaping @Sendable (MCRFrame) -> Bool) async throws -> MCRFrame {
        let req = MCRFrame.parse(frame)!
        sent.append(req)
        let payload: [UInt8]
        switch (req.commandType, req.functionCode) {
        case (0x02, 0x00): payload = req.payload + [UInt8(client >> 8), UInt8(client & 0xFF)]
        case (0x42, 0x25): payload = [0x02, 0, 0, 0x06, 0, 0, 0]   // legacy FF3, split, foot+massage
        case (0x42, 0x12): payload = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        default: payload = []
        }
        // Reply as the bed: SA slot = our client address, echo slot = bed address.
        var reply = try MCRFrame.build(commandType: req.commandType, functionCode: req.functionCode | 0x80,
                                       side: req.side, payload: payload, subAddress: 0, clientAddress: 0)
        let bound = req.functionCode != 0x00
        reply[3] = UInt8(bed >> 8); reply[4] = UInt8(bed & 0xFF)               // target
        reply[5] = bound ? UInt8(client >> 8) : 0; reply[6] = bound ? UInt8(client & 0xFF) : 0  // SA
        reply[8] = bound ? UInt8(bed >> 8) : 0; reply[9] = bound ? UInt8(bed & 0xFF) : 0        // echo
        let body = Array(reply[2..<(reply.count - 2)])
        let crc = mcrCRC(body)
        reply[reply.count - 2] = UInt8(crc >> 8); reply[reply.count - 1] = UInt8(crc & 0xFF)
        let parsed = MCRFrame.parse(reply)!
        guard matching(parsed) else { throw MCRResponseTimeout(functionCode: req.functionCode) }
        return parsed
    }
}

private func status(_ status: UInt8 = 0x40, positions: [UInt8] = [0, 0, 0, 0], flags: [UInt8] = [0, 0, 0, 0],
                    presets: UInt8 = 0x44) -> [UInt8] {
    [status] + positions + [0, 0, 0, 0] + flags + [0, presets]
}

@Suite("Session")
struct SessionTests {
    @Test func flatRecoversHomingAndReleases() async throws {
        let bed = FakeBed(statuses: [
            status(0x60, positions: [30, 0, 20, 0]),                       // pre-check: needs homing
            status(0x61, positions: [15, 0, 10, 0], flags: [1, 0, 1, 0]),  // moving
            status(positions: [0, 0, 0, 0]),
        ])
        let session = MCRSession(link: bed)
        let binding = try await session.bind(clientID: 0x0102_0304_0506_0708)
        #expect(binding == MCRBinding(clientAddress: 0x1234, bedAddress: 0x5678))
        let system = try await session.foundationSystem()
        #expect(system.model == .ff3 && system.sides == [.right, .left] && system.hasFoot)

        let final = try await session.preset(.flat, side: .right, system: system)
        #expect(final.rightHead.position == 0 && !final.needsHoming)

        let ops = bed.sent.map { "\(String($0.commandType, radix: 16)):\(String($0.functionCode, radix: 16))" }
        #expect(ops.first(where: { $0 == "42:15" }) != nil)
        #expect(bed.sent.contains { $0.functionCode == 0x15 && $0.payload == [4, 0] && $0.side == 0 })
        // Released with SE stop MFHR110, then a final status read.
        #expect(Array(ops.suffix(2)) == ["52:1b", "42:12"])
        #expect(bed.sent[bed.sent.count - 2].payload == Array("MFHR110".utf8))
    }

    @Test func refusesToMoveWithActuatorFault() async throws {
        let bed = FakeBed(statuses: [status(flags: [0, 0, 0x10, 0])])
        let session = MCRSession(link: bed)
        _ = try await session.bind(clientID: 1)
        let system = try await session.foundationSystem()
        await #expect(throws: MCRSessionError.self) {
            try await session.preset(.flat, side: .right, system: system)
        }
        #expect(!bed.sent.contains { $0.functionCode == 0x15 })
    }
}
