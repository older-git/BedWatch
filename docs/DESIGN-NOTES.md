# BedWatch — design notes + MCR protocol reference

Started as the project brief (2026-11-06) and kept up to date as the protocol was validated on
real hardware. Sections 1–5 are context and decisions. Section 6 is the protocol reference;
hardware-confirmed corrections to ha_smartbed are marked **Hardware-confirmed**.

---

## 1. Goal

A minimal watchOS app that replaces the Sleep Number remote and app for the two things the author
actually does, usually half-asleep:

1. Raise/lower **firmness** (Sleep Number setting) on either side of the bed.
2. Raise/lower **head** and **foot** incline of the FlexFit base.

Plus two convenience buttons: **Favorite** (recall saved position) and **Flat**.

Nothing else. No sleep tracking, no massage, no lights, no phone app dependency.

UI sketch: one screen per side (or a side toggle), six large buttons — firmness ±, head ±,
foot ± — plus Flat and Favorite. Haptic on command acknowledged.

## 2. Hardware identified

BLE scanner on the bed's pump reports:

| Field | Value |
|---|---|
| Model number | `SMART Sleep Smart Pump` |
| Manufacturer | `Select Comfort/BAM` |
| Software revision | `0.4.1d9` |
| Hardware revision | `EVT3` |
| Advertised service | `ffffd1fd-388d-938b-344a-939d1f6efee0` ✅ confirmed |

That service UUID identifies the **MCR / BAM transport** (older Sleep Number BLE generation, as
opposed to the newer "Fuzion" transport used by Climate 360 / FlexFit Smart). BAM Labs was the
company Sleep Number acquired in 2015 for SleepIQ, hence the manufacturer string.

**Confirmed on hardware 2026-11-06** (`bedctl`, log `logs/flat-1.log`):

| Field | Value |
|---|---|
| Advertised name | the pump's BLE MAC address, e.g. `64:db:a0:xx:xx:xx` |
| Manufacturer data | `534e 92 06 00 00 00` — company `"SN"`, flags `0x92` (both chambers), `06` = 360 pump |
| Foundation system (`0x42 FN=0x25`) | `00 64 64 14 15 00 00` → **360 FF2**, configuration 0 = **single-piece base** (one side, "right"), foot motor, under-bed light, no massage/warming |
| Presets | Favorite, Flat, Zero G, Snore |
| Firmness | per side (left / right chambers) |

The pump relays foundation commands; there is one BLE endpoint.

**Advertising gotcha:** when a client's link goes stale (phones used for scanning, the SN app),
the pump stops advertising and does not recover by itself; only a pump power-cycle fixed it.
After power-on it took **~60 s** to start advertising. The Watch app must always disconnect
cleanly. With all other Bluetooth devices off, the bed's remote did *not* block the connection.

## 3. Architecture decision: direct BLE from the Watch

Three options were considered:

| Option | Verdict | Why |
|---|---|---|
| **A. Watch → iPhone → SleepIQ cloud API** | Rejected | Undocumented cloud API (reverse-engineered since 2016, `asyncsleepiq`). Sleep Number has previously forced a Homebridge plugin to shut down for ToS violation and threatened IP blacklisting. HA users report auth expiring every ~48 h since Sept 2026. Round-trip latency through their cloud. Requires the phone. |
| **B. Watch → bed directly over BLE** | **Chosen** | No cloud, no login, no phone, instant. MCR transport needs **no OS-level pairing/bonding** (Fuzion would). Protocol fully mapped by `ha_smartbed` (§5). Risk: that mapping is from APK static analysis, not hardware testing — the author's bed was the hardware test. |
| C. Watch → Home Assistant → bed | Fallback / validation rig | Running `ha_smartbed` on a Raspberry Pi is a cheap way to prove the protocol against this exact bed before writing Swift. Not the end state. |

Design consequences of B:

- **watchOS CoreBluetooth as central.** Standalone Watch app; no WatchConnectivity needed.
- **The bed accepts exactly one BLE client** (and a stale client link silences advertising until
  the pump is power-cycled; see §2). The Sleep Number app on any phone in the house
  must be force-quit, or the pump won't be connectable. The Watch app should connect on demand,
  not hold a permanent link.
- **Old firmware dislikes reconnect churn during handshake.** Keep the link open ~30 s after
  the last tap so a burst of adjustments doesn't rebind every time. Bind is per-connection.
- **Head/foot: use the SE absolute-position write, not microadjust.** "Head to 35 %" is a Sleep
  Expert key write (`MFUR` + `"35_0"`, §6.3a); the bed drives there and stops. So "head up" =
  read current % → add step (5–10) → send. Good fit for one-tap wrist UI. *(Corrected
  2026-11-06 — see §6.3.)*
- **Every motion needs a stop path.** ha_smartbed always ends a move (normal, error, timeout or
  cancel) with an SE stop (`MFHR`/`MFHL` + `"110"`). The Watch app should do the same, and a
  tap during motion should send stop.

## 4. Validation plan (do this before Xcode)

Use **nRF Connect for Mobile** (Nordic; Android or iOS) — it enumerates services/characteristics,
subscribes to notifications, and writes raw bytes. On Windows, **Bluetooth LE Explorer**
(Microsoft Store) does the same, less elegantly. For capturing the *official* app's traffic if
needed: PacketLogger (Xcode Additional Tools) with the iOS Bluetooth logging profile, or Android
"Bluetooth HCI snoop log" + Wireshark.

**Status 2026-11-06:** all five steps passed on hardware via `bedctl` (on a Mac), not nRF
Connect. Head → 20 % and foot → 15 % via SE absolute writes landed exactly (≈7 s and ≈4 s);
firmness worked once the pump-status side order was corrected (§6.2).

Order:

1. Subscribe to notify char `…fee1`. Write the **bind** frame (§6.1) to `…fee2`. Expect a reply
   with `FN = 0x80` and a payload ≥ 10 bytes. **This is the gate for the whole protocol.** If it
   fails, firmware 0.4.1d9 differs from the APK model and you're sniffing the real app.
2. Foundation status read (§6.3). Decode positions; compare to the remote's display.
3. **Flat** preset (§6.4). Low-risk, obvious result.
4. Head to 20 % via SE absolute write `MFUR20_0` (§6.3a). Poll status (`SIDE=0`) until three
   consecutive non-moving reads; confirm position within ±3. Have the stop frame (§6.3b) ready.
5. Firmness ±5 on one side (§6.2).
6. Then open Xcode.

Alternative to steps 1–5: install `ha_smartbed` via HACS on a Pi with a BT adapter, let it
auto-detect the bed, and drive it from the HA UI. If that works, the protocol is proven.

## 5. Source of the protocol

`https://github.com/kristofferR/ha_smartbed` — Home Assistant custom integration for BLE
adjustable beds, many brands. Sleep Number MCR implementation:

- `custom_components/adjustable_bed/beds/sleep_number_mcr.py` (~1,900 lines; framing, bind,
  commands, response correlation, motion monitoring)
- `custom_components/adjustable_bed/beds/sleep_number_mcr_protocol.py` (decoders, preset IDs,
  capability flags)
- `docs/beds/sleep_number.md`, `docs/beds/sleep-number-mcr-disposition.md` (discovery ledger —
  which APK findings are implemented and which tests cover them)
- `tests/test_sleep_number_mcr.py` — frozen packet fixtures; useful as golden vectors for a
  Swift port. **Done:** `MCRProtocol/` (Swift package in this folder) encodes all 16 transport
  vectors byte-for-byte; `swift test` passes (ha_smartbed @ `608dae3c`).

Provenance: static analysis of SleepIQ Android 5.4.11. Project status "partially tested";
hardware validation explicitly pending. Internally consistent and fixture-tested, so reasonable
confidence, but confirm on the bed.

Other context, for completeness:

- `asyncsleepiq` (PyPI) — cloud API client; its `actuator.py` / `foundation.py` show the cloud
  endpoints (`bed/{id}/foundation/adjustment/micro`, `…/adjustment`). Not used here.
- Home Assistant core `sleepiq` integration — cloud-based; exposes firmness numbers, actuator
  position numbers, preset select. Not used here.

---

## 6. MCR BLE protocol — Watch remote subset

**Every byte below is from the ha_smartbed source, not from hardware. Confirm on the bed.**

### GATT

| Role | UUID |
|---|---|
| Service | `ffffd1fd-388d-938b-344a-939d1f6efee0` |
| Notify (bed → you, "TX") | `ffffd1fd-388d-938b-344a-939d1f6efee1` |
| Write (you → bed, "RX") | `ffffd1fd-388d-938b-344a-939d1f6efee2` |

- No OS-level pairing/bonding.
- One BLE client at a time.
- Project waits 128 ms after service discovery before enabling notifications.
- Writes chunked at ATT MTU − 3. Prefer write-with-response; fall back to without-response.
- Responses may be fragmented across notifications: buffer, scan for `16 16`, parse by length.

### Frame layout (both directions)

```
16 16 | CT | CA_hi CA_lo | SA_hi SA_lo | ST | CA_hi CA_lo | FN | (SIDE<<4)|LEN | payload[LEN] | CRC_hi CRC_lo
```

| Field | Meaning |
|---|---|
| `16 16` | sync |
| `CT` | command type / node: `0x02` pump, `0x42` foundation |
| `CA` | client address (16-bit, assigned at bind; `0x0000` before bind) — appears **twice** |
| `SA` | sub-address = bed address (assigned at bind; `0x0000` before bind) |
| `ST` | status byte; project always sets it equal to `CT` |
| `FN` | function/opcode. Bed sets bit 7 (`0x80`) on responses |
| `SIDE` | high nibble: `0` = right, `1` = left, `0xF` = all. Low nibble = payload length (≤ 15) |
| `CRC` | 16-bit, big-endian, over CT through end of payload |

CRC (Fletcher-style):
```swift
func mcrCRC(_ body: [UInt8]) -> UInt16 {
    var s = 0, r = 0
    for b in body { s += Int(b); r += s }
    return UInt16(r & 0xFFFF)
}
```

Parse a response: check sync, CRC, `len ≥ 14`; `target = body[1..2]`, `echo = body[6..7]`,
`fn = body[8] & 0x7F`, `isResponse = body[8] & 0x80`, `side = body[9] >> 4`,
`len = body[9] & 0x0F`.

Correlate reply to request by `(fn, side)`. Timeout 900 ms; retry up to 3 more times.

### 6.1 Bind (once per connection)

Generate a random **nonzero** 64-bit client ID once and persist it (UserDefaults). Not derived
from MAC.

```
CT=0x02 ST=0x02 FN=0x00 SIDE=0 CA=0x0000 SA=0x0000 payload = clientID (8 bytes, big-endian)
```

Response: `bedAddress = frame.target` (body[1..2]); `clientAddress = payload[8..9]`
(big-endian). Payload must be ≥ 10 bytes or bind failed. Thereafter every frame uses
`CA = clientAddress` (both slots) and `SA = bedAddress`.

### 6.2 Firmness (Sleep Number setting)

Value 5–100, snapped to multiples of 5. Two frames:

```
# force pump idle first
CT=0x02 ST=0x02 FN=0x02 SIDE=0 payload=[]
# then set
CT=0x02 ST=0x02 FN=0x11 SIDE=side payload=[0x00, value]
```

**Hardware-confirmed 2026-11-06:** `SIDE=1` = left, `SIDE=0` = right (as you lie in bed;
matches the remote). Pump status reply (`FN=0x12`) payload is `[adjusting, RIGHT, LEFT, 00, 00]`
with `SIDE=1` meaning dual chamber — **ha_smartbed decodes [1]/[2] as left/right, which is
backwards**. A 50→55 change took ~5 s; 55→50 about 1 s. ForceIdle reply has `SIDE=0xF`, empty.

If you abort mid-inflate, send ForceIdle again and poll pump status (`CT=0x02 FN=0x12`) until
inactive. Favorites read: `CT=0x02 FN=0x14` (payload holds right/left favorite values).
Firmness favorite store: `CT=0x02 FN=0x13 SIDE=side`.

### 6.3 Head / foot position

> **Correction (2026-11-06, after reading the ha_smartbed source and tests).** An earlier version
> of this brief described `0x42 FN=0x11` microadjust as an absolute target the bed reaches and
> then stops at, and said the SE layer could be skipped. That is not how ha_smartbed uses it.
> Microadjust is a **held** motion that must be kept alive by polling and ended with an explicit
> **SE stop**. Absolute positioning is an **SE key write**. So the Watch needs the SE short-write
> frame (`0x52 FN=0x1B`) for both. Golden vectors: `MCR-stop-right`, plus `test_se_command_payloads`
> and `test_absolute_target_waits_for_stable_feedback`.

SE short write (all of §6.3a/b), max 4-byte ASCII key + ≤ 11-byte value:
```
CT=0x52 ST=0x52 FN=0x1B SIDE=0 payload = key(4, ASCII) + value
```
A reply with `SIDE=0xF` means the SE layer rejected the request.

#### 6.3a Absolute position (use this for ± buttons)

| Axis / side | Key | Value |
|---|---|---|
| Head right / left | `MFUR` / `MFUL` | ASCII `"<pct>_0"`, e.g. `"50_0"` |
| Foot right / left | `MFFR` / `MFFL` | same |

Sequence (`_set_position`):
1. Pre-check status (`0x42 FN=0x12 SIDE=0`): refuse if not configured (`[0] & 0x40 == 0`),
   needs homing (`[0] & 0x20`), or any actuator on that side has a fault flag (`flags & 0x7E`).
   On 360-generation bases, also read pinch status `0x42 FN=0x28` (5 bytes) and remember it.
2. Send the SE write.
3. Wait 1.0 s, then poll status with `SIDE=0`: 333 ms between reads while any actuator is
   moving, 500 ms while still. Done after **3 consecutive non-moving reads**; success if the
   position is within ±3 of the target. Overall timeout 120 s.
4. **Always** finish with SE stop for that side (§6.3b), then one final status read, even on
   error or cancel. If the pinch counter changed or shows a fault, report an obstruction.

#### 6.3b Stop

```
SE write key = "MFHR" (right) / "MFHL" (left), value = ASCII "110"
→ 16 16 52 CA CA SA SA 52 CA CA 1B 07 4D 46 48 52 31 31 30 CRC
```

#### 6.3c Microadjust (held motion; not needed for the Watch)

```
CT=0x42 ST=0x42 FN=0x11 SIDE=side payload = 12 bytes, all 0xFF, except:
    head: payload[0..1] = [target, 0x00]
    foot: payload[2..3] = [target, 0x00]
```
`0xFF` = "leave unchanged." ha_smartbed uses it for hold-to-move (target 100 or 0): send it,
then poll status with `SIDE = side + 2` (the "keep adjusting" selector) every 333 ms for the
hold duration, then send SE stop. Without the keep-alive polls and the stop, how it behaves
is unknown.

#### Foundation status (`CT=0x42 FN=0x12`)

`SIDE=0` = plain read; `SIDE=side+2` = read and keep a held microadjust alive.

Foundation status payload (≥ 15 bytes):

| Byte | Meaning |
|---|---|
| `[0]` | bit0 moving, bit5 needs homing, bit6 configured |
| `[1]` `[2]` `[3]` `[4]` | position %: R head, L head, R foot, L foot |
| `[5..6]` `[7..8]` | LE timers R / L |
| `[9..12]` | per-actuator flags (same order): bit0 moving, bit1 limit missing, bit2 limit unexpected, bit3 under-current, bit4 over-current, bit5 no movement, bit6 unexpected movement |
| `[13]` | timer preset nibbles (R low, L high) |
| `[14]` | active preset nibbles (R low, L high) — preset IDs below |

**Needs-homing:** if `[0] & 0x20`, send Flat for that side before anything else moves.

### 6.4 Presets

```
CT=0x42 ST=0x42 FN=0x15 SIDE=side payload=[presetID, 0x00]
```

| Preset | ID | Available on |
|---|---|---|
| Favorite | 1 | all |
| Read | 2 | FF3 |
| Watch TV | 3 | FF3 |
| Flat | 4 | all |
| Zero G | 5 | FF2/FF3 |
| Snore | 6 | FF2/FF3 (and 360 FF1) |

Save current position as Favorite: `CT=0x42 FN=0x16 SIDE=side payload=[1]`.

Caveat: on some base layouts a per-side preset moves both sides.

Observed on the single-piece FF2: Flat sent to side right set **both** preset nibbles to Flat
(`[14] = 0x44`) while moving; after the SE stop the right nibble cleared (`0x40`). So confirm the
preset before stopping, which is what ha_smartbed does.

ha_smartbed runs presets through the same flow as §6.3a: pre-check, wait until 3 consecutive
non-moving reads, confirm the side's active-preset nibble (`[14]`) equals the requested ID,
then SE stop + final read. If the bed acks but the preset nibble never changes, that's a
failure, not a success. Flat is allowed while needs-homing is set; success requires the flag to
clear.

### 6.5 Capabilities (optional, once)

Foundation system status → FF1/FF2/FF3 and whether a foot motor exists. See `decode_system()`
in `sleep_number_mcr_protocol.py` for opcode and bit layout (`payload[3]` flags: bit1 massage,
bit2 foot, bit3 warming, bit4 light; `payload[0]` configuration: 1 or 2 → two articulation sides).

### Not needed (skip)

- SE *long* reads/writes (`FN=0x1C`/`0x1D`, chunked with CRC32). Only the SE **short write**
  (`FN=0x1B`, §6.3) is needed.
- Microadjust hold-to-move (§6.3c).
- Massage, outlets, under-bed light, foot warming, pinch sensors.

---

## 7. Open questions for the coding session

- ~~Does bind succeed on firmware 0.4.1d9?~~ **Yes.** Bed address = last 2 bytes of the MAC
  (`0xa54c`); assigned client address = last 2 bytes of the client ID. Replies come back with
  node − 1 (`0x01` pump, `0x41` foundation, `0x51` SE).
- ~~FF1/FF2/FF3?~~ **360 FF2, single-piece base** (§2): one side, foot motor present.
- ~~Does the pump relay foundation commands, or is the base a separate BLE peripheral?~~
  **The pump relays them; single endpoint.**
- How does the firmware tolerate connect/bind/disconnect on every Watch wake? Decide the
  link-hold timeout empirically.
- Step size for head/foot ± buttons (5 %? 10 %?). Taste.
- ~~Does the SE layer respond?~~ **Yes** — `MFHR110` stop acked (`0x51 FN=0x9B`, empty payload).
  Absolute position (`MFUR20_0`, `MFFR15_0`) confirmed: exact, acked `0x51 FN=0x9B`.
- Bed presence: ha_smartbed found no dependable MCR occupancy method. Pump-status bytes [3..4]
  are undecoded (always `00 00` so far); worth watching while someone gets in/out.
- ~~Does the pump re-advertise after a clean disconnect, without a power-cycle?~~ **Yes.** Next
  `bedctl info`: found in 4.3 s, bound 1.5 s later, status read by 6.6 s (cold, from a Mac
  scan). Connect-on-demand is viable; keep the link ~30 s after the last tap to avoid paying
  ~6 s per burst. Node list: `71 01 51 41` (discovery, pump, SE, foundation). Pump status
  `00 32 32` = idle, L 50, R 50, dual chamber.

---

## 8. Watch app (started 2026-11-06)

- `project.yml` (XcodeGen) → `BedWatch.xcodeproj`; regenerate with `xcodegen generate`.
  Watch-only app (`WKWatchOnly`), watchOS 10+, bundle ID `local.bedwatch.BedWatch`.
- Sources in `WatchApp/`: `BedController` (connect on demand, 30 s link hold, clean disconnect
  on background or failed connect, tap coalescing), `ContentView` (page 1: head/foot ±10 %,
  Flat, Favorite, Stop while moving; page 2: firmness ±5 with a left/right toggle).
- Uses `MCRProtocol` + `MCRBluetooth` from the local package unchanged.
- Builds for watchOS device and simulator (unsigned). Bluetooth doesn't work in the simulator,
  so testing on the bed needs a signed install on the Ultra.
- Complications (`WidgetExtension/`, target `BedWatchWidgets`): **Bed Remote** launcher, and
  **Temp + Humidity** in one slot from Open-Meteo (no key), current location rounded to
  ~1 km, refreshed every 30 min, last fix cached. The app requests location on first launch
  (widgets can't prompt). Switch to WeatherKit once the paid developer account exists.
