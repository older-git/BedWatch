// bedctl — drive the Sleep Number MCR pump from the Mac for protocol validation.
//
//   bedctl scan [seconds]          list every advertising BLE device (no connection)
//   bedctl info                    read-only: bind, nodes, pump, foundation system + status
//   bedctl flat [both|right|left]  Flat preset (also homing recovery)
//   bedctl stop [both|right|left]  SE stop
//   bedctl head <0-100> [side]     SE absolute position (side defaults to the base's first side)
//   bedctl foot <0-100> [side]
//   bedctl firmness <left|right> <5-100>
//
//   --id <UUID>   connect to this peripheral (from `bedctl scan`) instead of scanning for the
//                 MCR service UUID
//
// Every frame is logged as hex. Force-quit the Sleep Number app on phones first: the pump
// accepts one BLE client at a time.

import Foundation
import MCRBluetooth
import MCRProtocol

let start = ContinuousClock.now
@Sendable func log(_ message: String) {
    let t = ContinuousClock.now - start
    let ms = t.components.seconds * 1000 + t.components.attoseconds / 1_000_000_000_000_000
    FileHandle.standardError.write(Data(String(format: "[%7.3f] %@\n", Double(ms) / 1000, message).utf8))
}

func say(_ message: String) { print(message); fflush(stdout) }

/// Random nonzero 64-bit client ID, persisted so the pump sees the same client every run.
func clientID() throws -> UInt64 {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BedWatch", isDirectory: true)
    let file = dir.appendingPathComponent("client-id")
    if let text = try? String(contentsOf: file, encoding: .utf8),
       let id = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16), id != 0 {
        return id
    }
    var id: UInt64 = 0
    while id == 0 { id = UInt64.random(in: .min ... .max) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try String(id, radix: 16).write(to: file, atomically: true, encoding: .utf8)
    return id
}

func sides(_ arg: String?, system: FoundationSystem) throws -> [MCRSide] {
    switch arg ?? "both" {
    case "both": return system.sides
    case "right": return [.right]
    case "left": return [.left]
    default: throw MCRSessionError.badPayload("side must be both|right|left")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var peripheralID: UUID?
if let i = args.firstIndex(of: "--id"), i + 1 < args.count {
    peripheralID = UUID(uuidString: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
let usage = "usage: bedctl [--id UUID] scan [s] | info | flat [side] | stop [side] | head <pct> [side] | foot <pct> [side] | firmness <left|right> <5-100>"
guard let command = args.first, ["scan", "info", "flat", "stop", "head", "foot", "firmness"].contains(command) else {
    say(usage)
    exit(2)
}

func side(_ name: String) throws -> MCRSide {
    switch name {
    case "right": return .right
    case "left": return .left
    default: throw MCRSessionError.badPayload("side must be right|left")
    }
}

let link = MCRBluetoothLink(log: log)
let session = MCRSession(link: link, log: log)

if command == "scan" {
    do {
        let seconds = args.dropFirst().first.flatMap { Int($0) } ?? 10
        say("Scanning \(seconds) s…")
        for s in try await link.survey(duration: .seconds(seconds)) {
            let mcr = s.services.contains { $0.caseInsensitiveCompare(MCRBluetoothLink.serviceUUID.uuidString) == .orderedSame }
            say("\(mcr ? "MCR " : "    ")\(s.identifier)  \(String(format: "%4d", s.rssi)) dBm  \(s.name ?? "-")"
                + (s.services.isEmpty ? "" : "  services \(s.services)")
                + (s.manufacturerData.map { "  mfr \(hex($0))" } ?? "")
                + (s.connectable == false ? "  (not connectable)" : ""))
        }
        exit(0)
    } catch {
        say("ERROR: \(error)")
        exit(1)
    }
}

do {
    try await link.connect(identifier: peripheralID)
    say("Connected to \(link.peripheralName ?? "pump")")
    let id = try clientID()
    let binding = try await session.bind(clientID: id)
    say(String(format: "Bound: client 0x%04x, bed 0x%04x (client id %016llx)",
               binding.clientAddress, binding.bedAddress, id))

    let system = try await session.foundationSystem()
    say("Foundation: \(system.generation.rawValue) \(system.model.rawValue), configuration \(system.configuration), "
        + "sides \(system.sides), foot \(system.hasFoot), massage \(system.hasMassage), "
        + "warming \(system.hasWarming), light \(system.hasLight) [raw \(hex(system.raw))]")
    say("Presets: \(system.presets)")

    switch command {
    case "info":
        do {
            say("Nodes: \(try await session.nodes().map { String(format: "0x%02x", $0) })")
        } catch { say("Nodes: \(error)") }
        do {
            let pump = try await session.pumpStatus()
            say("Pump: firmness L \(pump.left) R \(pump.right), adjusting \(pump.adjusting), dual \(pump.dualChamber)")
        } catch { say("Pump: \(error)") }
        say("Status: \(describe(try await session.foundationStatus()))")

    case "flat":
        for side in try sides(args.dropFirst().first, system: system) {
            say("Flat \(side)…")
            let final = try await session.preset(.flat, side: side, system: system)
            say("Flat \(side) done: \(describe(final))")
        }

    case "stop":
        for side in try sides(args.dropFirst().first, system: system) {
            try await session.stop(side: side)
            say("Stopped \(side)")
        }
        say("Status: \(describe(try await session.foundationStatus()))")

    case "head", "foot":
        guard args.count >= 2, let pct = UInt8(args[1]), pct <= 100 else { say(usage); exit(2) }
        let axis: MCRAxis = command == "head" ? .head : .foot
        let s = try args.count >= 3 ? side(args[2]) : system.sides[0]
        say("\(command) \(s) → \(pct)%…")
        let final = try await session.setPosition(axis, to: pct, side: s, system: system)
        say("Done: \(describe(final))")

    case "firmness":
        guard args.count >= 3, let value = Int(args[2]) else { say(usage); exit(2) }
        let s = try side(args[1])
        let before = try await session.pumpStatus()
        say("Firmness before: L \(before.left) R \(before.right). Setting \(s) → \(snapFirmness(value))…")
        let after = try await session.setFirmness(value, side: s)
        say("Firmness after: L \(after.left) R \(after.right)")

    default:
        break
    }
    link.disconnect()
    exit(0)
} catch {
    say("ERROR: \(error)")
    link.disconnect()
    exit(1)
}
