# BedWatch

**An Apple Watch remote for Sleep Dumber™ beds.**

Raise the head, lower the foot, go flat, change firmness — straight from your wrist to the
bed's pump over Bluetooth. No cloud, no account, no phone, no app that logs you out every two
days. Built for half-asleep use: big buttons, haptics, one screen.

> **Unofficial.** Not affiliated with, endorsed by, or supported by Sleep Number Corporation.
> "Sleep Number" is their trademark; "Sleep Dumber" is a joke. This talks to your bed using a
> protocol worked out by the community, not a published API. It moves a motorized bed and an
> air pump — use it at your own risk (see [License](#license)).

## What's in here

| Part | What it is |
|---|---|
| `WatchApp/` | The watchOS app: head/foot ±10 %, Flat, Favorite, Stop, firmness ±5 per side, plus a small Weather page |
| `WidgetExtension/` | Complications: **Bed Remote** (opens the app) and **Temp + Humidity** in a single slot |
| `MCRProtocol/` | Swift package: the MCR wire protocol (`MCRProtocol`), a CoreBluetooth transport (`MCRBluetooth`), and `bedctl`, a Mac command-line tool for testing against a real bed |
| `docs/DESIGN-NOTES.md` | Protocol reference and everything learned validating it on hardware |

## Will it work with my bed?

Probably only if your bed is the **older "BAM / MCR" generation**: the pump advertises the
Bluetooth service `ffffd1fd-388d-938b-344a-939d1f6efee0`. Newer beds (Climate 360, FlexFit
Smart on the "Fuzion" transport) use a different protocol and **won't work**.

Tested on one bed: *SMART Sleep Smart Pump*, firmware 0.4.1d9, with a single-piece FlexFit 2
("360 FF2") base and dual air chambers. Split bases should work (the code handles them) but
haven't been tested.

The quickest check: build `bedctl` (below) and run `bedctl scan`. If a line starts with `MCR`,
you're in business. `bedctl info` is read-only and tells you your base model and firmness.

## Building

Requirements: a Mac with Xcode (Swift 6 / watchOS 10 SDK or newer) and an Apple Watch on
watchOS 10+. A free Apple developer account works, but apps signed with one expire after 7
days and need reinstalling.

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and put in your team ID and a
   bundle ID prefix of your own.
2. Open `BedWatch.xcodeproj`, choose your Watch as the run destination, press Run.
   (The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
   run `xcodegen generate` after changing it.)
3. On first launch, allow Bluetooth (for the bed) and Location (for the weather complication).

Force-quit the Sleep Number app on your phone(s) first: **the pump accepts one Bluetooth
client at a time.**

### bedctl (Mac)

```
cd MCRProtocol
swift build
.build/debug/bedctl scan            # list nearby Bluetooth devices
.build/debug/bedctl info            # read-only: base model, positions, firmness
.build/debug/bedctl flat            # Flat preset
.build/debug/bedctl head 20         # head to 20 %
.build/debug/bedctl foot 15
.build/debug/bedctl firmness left 55
.build/debug/bedctl stop
```

Every frame sent and received is logged as hex on stderr. `swift test` runs the protocol tests,
including frames captured from a real bed.

## Things that will bite you

- **One client at a time.** While anything else is connected (phone app, `bedctl`, the Watch
  app), nobody else can connect.
- **A stale connection silences the pump.** If a client disappears without disconnecting, the
  pump stops advertising until it's **power-cycled** (unplug the pump ~30 s; it takes about a
  minute to come back). The app always disconnects cleanly for this reason.
- **ha_smartbed has the pump-status sides backwards.** The firmness reply is
  `[adjusting, RIGHT, LEFT]`, confirmed against the bed's own remote. See the design notes.

## Credits

- The protocol comes from [ha_smartbed](https://github.com/kristofferR/ha_smartbed) by
  kristofferR (MIT), a Home Assistant integration for many adjustable beds. Its Sleep Number MCR
  implementation and frozen test vectors made this possible; parts of `MCRProtocol` are a Swift
  port of it.
- Weather data by [Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0).

## License

MIT — see [LICENSE](LICENSE), which also carries ha_smartbed's license for the ported parts.
Provided as is, without warranty of any kind.
