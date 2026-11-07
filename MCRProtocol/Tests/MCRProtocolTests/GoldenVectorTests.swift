// Golden vectors copied from ha_smartbed tests/test_sleep_number_mcr.py
// (kristofferR/ha_smartbed @ 608dae3c). Those are frozen against the Python frame builder,
// not captured from hardware.

import Testing
@testable import MCRProtocol

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

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

struct TransportVector: CustomTestStringConvertible, Sendable {
    let name: String
    let node: UInt8
    let opcode: UInt8
    let sub: UInt8
    let payload: String
    let client: UInt16
    let peer: UInt16
    let expected: String
    var testDescription: String { name }
}

// test_all_frozen_transport_vectors
private let transportVectors: [TransportVector] = [
    .init(name: "MCR-bind", node: 2, opcode: 0, sub: 0, payload: "0102030405060708", client: 0, peer: 0,
          expected: "161602000000000200000008010203040506070800fe"),
    .init(name: "MCR-pump-status", node: 2, opcode: 18, sub: 0, payload: "", client: 4660, peer: 22136,
          expected: "1616021234567802123412000892"),
    .init(name: "MCR-set-left-50", node: 2, opcode: 17, sub: 1, payload: "0032", client: 4660, peer: 22136,
          expected: "16160212345678021234111200320bd6"),
    .init(name: "MCR-head-right30", node: 66, opcode: 17, sub: 0, payload: "1e00ffffffffffffffffffff",
          client: 4660, peer: 22136, expected: "16164212345678421234110c1e00ffffffffffffffffffff5c51"),
    .init(name: "MCR-foot-left60", node: 66, opcode: 17, sub: 1, payload: "ffff3c00ffffffffffffffff",
          client: 4660, peer: 22136, expected: "16164212345678421234111cffff3c00ffffffffffffffff620d"),
    .init(name: "MCR-recall-favorite-left", node: 66, opcode: 21, sub: 1, payload: "0100", client: 4660,
          peer: 22136, expected: "16164212345678421234151201001076"),
    .init(name: "MCR-save-favorite-right", node: 66, opcode: 22, sub: 0, payload: "01", client: 4660,
          peer: 22136, expected: "161642123456784212341601010e51"),
    .init(name: "MCR-footwarm-left-high60", node: 66, opcode: 41, sub: 1, payload: "483c00", client: 4660,
          peer: 22136, expected: "161642123456784212342913483c001431"),
    .init(name: "MCR-massage-right-head-low30", node: 66, opcode: 17, sub: 0, payload: "ffffffff01ff00ffffff1e00",
          client: 4660, peer: 22136, expected: "16164212345678421234110cffffffff01ff00ffffff1e006127"),
    .init(name: "MCR-outlet-left-on", node: 146, opcode: 19, sub: 1, payload: "01ff00", client: 4660,
          peer: 22136, expected: "16169212345678921234131301ff001b04"),
    .init(name: "MCR-sense-enable", node: 50, opcode: 20, sub: 0, payload: "0100", client: 4660, peer: 22136,
          expected: "16163212345678321234140201000f12"),
    .init(name: "MCR-stop-right", node: 82, opcode: 27, sub: 0, payload: "4d464852313130", client: 4660,
          peer: 22136, expected: "161652123456785212341b074d46485231313023cf"),
    .init(name: "MCR-se-read", node: 82, opcode: 28, sub: 0, payload: "53575343", client: 4660, peer: 22136,
          expected: "161652123456785212341c0453575343190c"),
    .init(name: "MCR-se-long-select", node: 82, opcode: 29, sub: 2, payload: "53575343", client: 4660,
          peer: 22136, expected: "161652123456785212341d245357534319b2"),
    .init(name: "MCR-se-write-chunk", node: 82, opcode: 29, sub: 9, payload: "303132333435363738396162636465",
          client: 4660, peer: 22136, expected: "161652123456785212341d9f30313233343536373839616263646551d6"),
    .init(name: "MCR-se-terminal-write", node: 82, opcode: 29, sub: 10, payload: "", client: 4660, peer: 22136,
          expected: "161652123456785212341da00df8"),
]

@Suite("Frame builder")
struct FrameBuilderTests {
    @Test(arguments: transportVectors)
    func frozenTransportVector(_ v: TransportVector) throws {
        let frame = try MCRFrame.build(
            commandType: v.node, functionCode: v.opcode, side: v.sub, payload: bytes(v.payload),
            subAddress: v.peer, clientAddress: v.client)
        #expect(hex(frame) == v.expected)
    }

    @Test(arguments: transportVectors)
    func parseRoundTrip(_ v: TransportVector) throws {
        let frame = try #require(MCRFrame.parse(bytes(v.expected)))
        #expect(frame.commandType == v.node)
        #expect(frame.functionCode == v.opcode)
        #expect(frame.side == v.sub)
        #expect(hex(frame.payload) == v.payload)
        #expect(frame.target == v.client)
        #expect(frame.subAddress == v.peer)
        #expect(!frame.isResponse)
    }

    @Test func rejectsOversizedPayload() {
        #expect(throws: MCRError.payloadTooLong(16)) {
            try MCRFrame.build(commandType: 2, functionCode: 0, side: 0, payload: .init(repeating: 0, count: 16),
                               subAddress: 0)
        }
    }

    @Test func parseRejectsBadCRC() {
        var raw = bytes("1616021234567802123412000892")
        raw[raw.count - 1] ^= 0x01
        #expect(MCRFrame.parse(raw) == nil)
    }
}

@Suite("Watch-subset requests encode to the frozen vectors")
struct RequestEncodingTests {
    let client: UInt16 = 0x1234
    let bed: UInt16 = 0x5678

    @Test func bind() throws {
        // test_binding_requires_valid_reply uses client id 0x0102030405060708 with zero addresses.
        let frame = try MCRRequest.bind(clientID: 0x0102_0304_0506_0708).encode(clientAddress: 0, bedAddress: 0)
        #expect(hex(frame) == "161602000000000200000008010203040506070800fe")
    }

    @Test func pumpStatus() throws {
        #expect(hex(try MCRRequest.pumpStatus.encode(clientAddress: client, bedAddress: bed))
                == "1616021234567802123412000892")
    }

    @Test func setFirmnessLeft50() throws {
        #expect(hex(try MCRRequest.setFirmness(50, side: .left).encode(clientAddress: client, bedAddress: bed))
                == "16160212345678021234111200320bd6")
    }

    @Test func headRight30() throws {
        let r = try MCRRequest.microadjust(.head, to: 30, side: .right)
        #expect(hex(try r.encode(clientAddress: client, bedAddress: bed))
                == "16164212345678421234110c1e00ffffffffffffffffffff5c51")
    }

    @Test func footLeft60() throws {
        let r = try MCRRequest.microadjust(.foot, to: 60, side: .left)
        #expect(hex(try r.encode(clientAddress: client, bedAddress: bed))
                == "16164212345678421234111cffff3c00ffffffffffffffff620d")
    }

    @Test func recallFavoriteLeft() throws {
        #expect(hex(try MCRRequest.preset(.favorite, side: .left).encode(clientAddress: client, bedAddress: bed))
                == "16164212345678421234151201001076")
    }

    @Test func saveFavoriteRight() throws {
        #expect(hex(try MCRRequest.saveFavoritePosition(side: .right).encode(clientAddress: client, bedAddress: bed))
                == "161642123456784212341601010e51")
    }

    @Test func stopRight() throws {
        #expect(hex(try MCRRequest.stop(side: .right).encode(clientAddress: client, bedAddress: bed))
                == "161652123456785212341b074d46485231313023cf")
    }

    // test_preset_keeps_selected_side_and_monitors_recovery: (0x42, 0x15, selector, [id, 0])
    @Test func flatPresetPayload() {
        #expect(MCRRequest.preset(.flat, side: .left)
                == MCRRequest(node: .foundation, functionCode: 0x15, side: 1, payload: [4, 0]))
    }

    // test_frozen_command_payloads: firmness_favorite right 65 → (2, 0x13, 0, "41")
    @Test func firmnessFavoritePayload() {
        #expect(MCRRequest.saveFirmnessFavorite(65, side: .right)
                == MCRRequest(node: .pump, functionCode: 0x13, side: 0, payload: [0x41]))
    }

    // test_held_motion_keeps_selected_side_moving: selector = side + 2
    @Test func keepAdjustingSelectors() {
        #expect(MCRRequest.foundationStatus().side == 0)
        #expect(MCRRequest.foundationStatus(keepAdjusting: .right).side == 2)
        #expect(MCRRequest.foundationStatus(keepAdjusting: .left).side == 3)
    }

    // test_se_command_payloads / test_absolute_target_waits_for_stable_feedback
    @Test func absolutePositionSEKeys() throws {
        #expect(try MCRRequest.setPosition(.foot, to: 30, side: .left).payload == Array("MFFL30_0".utf8))
        #expect(try MCRRequest.setPosition(.head, to: 50, side: .right).payload == Array("MFUR50_0".utf8))
        #expect(MCRRequest.stop(side: .left).payload == Array("MFHL110".utf8))
    }

    @Test func rejectsPositionOver100() {
        #expect(throws: MCRError.self) { try MCRRequest.microadjust(.head, to: 101, side: .left) }
        #expect(throws: MCRError.self) { try MCRRequest.setPosition(.foot, to: 101, side: .left) }
    }

    @Test func firmnessSnapping() {
        #expect(snapFirmness(0) == 5)
        #expect(snapFirmness(7) == 5)
        #expect(snapFirmness(8) == 10)
        #expect(snapFirmness(65) == 65)
        #expect(snapFirmness(120) == 100)
    }
}

@Suite("Responses")
struct ResponseTests {
    // test_capability_and_state_vectors
    @Test func foundationStatusVector() throws {
        let s = try #require(FoundationStatus(payload: bytes("61320a461405000900010204082156")))
        #expect(s.rightHead.position == 50)
        #expect(s.rightHead.isMoving)
        #expect(s.rightPreset == .snore)
        #expect(s.leftPreset == .zeroG)
        #expect(s.rightTimer == 5)
        #expect(s.needsHoming)
        #expect(s.isConfigured)
    }

    @Test func foundationStatusRejectsShortPayload() {
        #expect(FoundationStatus(payload: .init(repeating: 0, count: 14)) == nil)
    }

    @Test func bindReplyAndFragmentedNotifications() throws {
        // Synthetic reply: bed at 0x5678 echoes client id + assigned client address 0x1234.
        let reply = try MCRFrame.build(
            commandType: 2, functionCode: 0x80, side: 0,
            payload: bytes("01020304050607081234"), subAddress: 0, clientAddress: 0x5678)
        var assembler = MCRFrameAssembler()
        // Leading garbage, then the frame split across 20-byte-MTU-sized notifications.
        #expect(assembler.append([0x00, 0xAA] + reply.prefix(18)).isEmpty)
        let frames = assembler.append(reply.dropFirst(18))
        #expect(frames.count == 1)
        #expect(frames[0].isResponse)
        #expect(frames[0].functionCode == 0)
        let binding = try #require(MCRBinding(replies: frames))
        #expect(binding == MCRBinding(clientAddress: 0x1234, bedAddress: 0x5678))
    }

    @Test func bindFailsWithoutAssignedAddresses() {
        #expect(MCRBinding(replies: [MCRFrame(commandType: 2, target: 0, subAddress: 0, status: 2, echo: 0,
                                              functionCode: 0, side: 0, payload: [], isResponse: true)]) == nil)
    }
}
