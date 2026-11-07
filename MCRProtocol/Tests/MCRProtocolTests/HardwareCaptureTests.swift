// Frames captured from a real bed with bedctl (2026-11-06): SMART Sleep Smart Pump fw 0.4.1d9,
// 360 FF2 single-piece base. The bed address 0xa54c is the last two bytes of the pump's BLE
// address; the client ID is bedctl's random one. RX lines are BLE notifications
// exactly as received, including how they were fragmented.

import Testing
@testable import MCRProtocol

private func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func assemble(_ notifications: String...) -> [MCRFrame] {
    var assembler = MCRFrameAssembler()
    return notifications.flatMap { assembler.append(bytes($0)) }
}

private let clientID: UInt64 = 0x05e1_7b4c_54e6_584e
private let binding = MCRBinding(clientAddress: 0x584e, bedAddress: 0xa54c)

@Suite("Hardware capture")
struct HardwareCaptureTests {
    @Test func bindRequestAndReply() throws {
        let tx = try MCRRequest.bind(clientID: clientID).encode(clientAddress: 0, bedAddress: 0)
        #expect(bytes("16160200000000020000000805e17b4c54e6584e1033") == tx)

        let frames = assemble("161601a54c000001a54c801a05e17b4c54e6584e", "584e3d7f")
        #expect(frames.count == 1)
        #expect(frames[0].commandType == 0x01)   // pump replies as node 0x01
        #expect(MCRSession.matcher(node: .pump, functionCode: 0x00, binding: nil)(frames[0]))
        #expect(MCRBinding(replies: frames) == binding)
    }

    @Test func requestsEncodeAsSent() throws {
        func tx(_ r: MCRRequest) throws -> [UInt8] {
            try r.encode(clientAddress: binding.clientAddress, bedAddress: binding.bedAddress)
        }
        #expect(try tx(MCRRequest(node: .foundation, functionCode: 0x25)) == bytes("161642584ea54c42584e25001245"))
        #expect(try tx(.foundationStatus()) == bytes("161642584ea54c42584e1200121f"))
        #expect(try tx(MCRRequest(node: .foundation, functionCode: 0x28)) == bytes("161642584ea54c42584e2800124b"))
        #expect(try tx(.preset(.flat, side: .right)) == bytes("161642584ea54c42584e1502040017df"))
        #expect(try tx(.stop(side: .right)) == bytes("161652584ea54c52584e1b074d4648523131302fd1"))
    }

    @Test func foundationSystem() throws {
        let frames = assemble("161641a54c584e41a54ca5070064641415000033", "d6")
        #expect(MCRSession.matcher(node: .foundation, functionCode: 0x25, binding: binding)(frames[0]))
        let system = try #require(FoundationSystem(payload: frames[0].payload))
        #expect(system.generation == .threeSixty && system.model == .ff2)
        #expect(system.configuration == 0 && system.sides == [.right])
        #expect(system.hasFoot && system.hasLight && !system.hasMassage && !system.hasWarming)
        #expect(system.presets == [.favorite, .flat, .zeroG, .snore])
    }

    @Test func statusBeforeDuringAndAfterFlat() throws {
        let before = try #require(FoundationStatus(payload: assemble(
            "161641a54c584e41a54c920f4022223939000000", "00000000000000585d")[0].payload))
        #expect(before.isConfigured && !before.needsHoming && !before.anyActuatorMoving)
        #expect(before.rightHead.position == 34 && before.rightFoot.position == 57)
        // Single-piece base mirrors right into left.
        #expect(before.leftHead.position == 34 && before.leftFoot.position == 57)

        let moving = try #require(FoundationStatus(payload: assemble(
            "161641a54c584e41a54c920f4120203434000000", "00000100010044580f")[0].payload))
        #expect(moving.isMoving && moving.anyActuatorMoving)
        #expect(moving.leftHead.isMoving && moving.leftFoot.isMoving && !moving.rightHead.isMoving)
        #expect(moving.rightPreset == .flat && moving.leftPreset == .flat)

        let final = try #require(FoundationStatus(payload: assemble(
            "161641a54c584e41a54c920f4000000000000000", "000000000000404fe8")[0].payload))
        #expect(!final.anyActuatorMoving && final.rightHead.position == 0 && final.rightFoot.position == 0)
        #expect(final.rightPreset == nil && final.leftPreset == .flat)
    }

    // logs: `bedctl info` reconnect run, no power-cycle.
    @Test func nodesAndPumpStatus() throws {
        let nodes = assemble("161671a54c584e71a54c9204710151412a52")
        #expect(MCRSession.matcher(node: .discovery, functionCode: 0x12, binding: binding)(nodes[0]))
        #expect(nodes[0].payload == [0x71, 0x01, 0x51, 0x41])

        let tx = try MCRRequest.pumpStatus.encode(clientAddress: binding.clientAddress, bedAddress: binding.bedAddress)
        #expect(tx == bytes("161602584ea54c02584e12000e5f"))
        let pump = assemble("161601a54c584e01a54c92150032320000227c")
        #expect(MCRSession.matcher(node: .pump, functionCode: 0x12, binding: binding)(pump[0]))
        #expect(pump[0].side == 1)   // dual chamber
        #expect(Array(pump[0].payload.prefix(3)) == [0x00, 50, 50])   // idle, R 50, L 50
    }

    // `bedctl firmness left 55`: remote confirmed left 55 / right 50 afterwards.
    @Test func firmnessLeft55() async throws {
        func tx(_ r: MCRRequest) throws -> [UInt8] {
            try r.encode(clientAddress: binding.clientAddress, bedAddress: binding.bedAddress)
        }
        #expect(try tx(.pumpForceIdle) == bytes("161602584ea54c02584e02000e3f"))
        #expect(try tx(.setFirmness(55, side: .left)) == bytes("161602584ea54c02584e11120037136e"))
        let idleAck = assemble("161601a54c584e01a54c82f011e4")
        #expect(MCRSession.matcher(node: .pump, functionCode: 0x02, binding: binding)(idleAck[0]))
        let setAck = assemble("161601a54c584e01a54c91001112")
        #expect(MCRSession.matcher(node: .pump, functionCode: 0x11, binding: binding)(setAck[0]))

        // Replay the final pump-status reply through the session decoder.
        let final = assemble("161601a54c584e01a54c92150032370000228b")[0]
        let session = MCRSession(link: Replay(frame: final))
        try await session.setBindingForTesting(binding)
        let pump = try await session.pumpStatus()
        #expect(pump == PumpStatus(adjusting: false, dualChamber: true, left: 55, right: 50))
    }

    @Test func pinchAndAcks() throws {
        let pinch = assemble("161641a54c584e41a54ca80500000000002798")
        let p = try #require(PinchStatus(payload: pinch[0].payload))
        #expect(!p.sensor(.head, side: .right).disconnected && p.sensor(.foot, side: .left).events == 0)

        let presetAck = assemble("161641a54c584e41a54c950014da")
        #expect(MCRSession.matcher(node: .foundation, functionCode: 0x15, binding: binding)(presetAck[0]))

        let stopAck = assemble("161651a54c584e51a54c9b0015d6")
        #expect(stopAck[0].commandType == 0x51 && stopAck[0].side == 0 && stopAck[0].payload.isEmpty)
        #expect(MCRSession.matcher(node: .sleepExpert, functionCode: 0x1B, binding: binding)(stopAck[0]))
    }
}

private struct Replay: MCRLink {
    let frame: MCRFrame
    func exchange(_ frame: [UInt8], timeout: Duration,
                  matching: @escaping @Sendable (MCRFrame) -> Bool) async throws -> MCRFrame { self.frame }
}
