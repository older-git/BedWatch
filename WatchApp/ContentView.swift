// Two vertical pages: the base (head, foot, Flat, Favorite) and firmness. Big targets for
// half-asleep use; a Stop button replaces the presets while the bed is moving.

import MCRProtocol
import SwiftUI

struct ContentView: View {
    let bed: BedController

    var body: some View {
        TabView {
            BaseView(bed: bed)
            FirmnessView(bed: bed)
        }
        .tabViewStyle(.verticalPage)
    }
}

/// Side margin on both pages: keeps the outer buttons clear of the system page dots beside
/// the Digital Crown while staying centered.
private let pageInset: CGFloat = 10

private struct BaseView: View {
    let bed: BedController

    var body: some View {
        VStack(spacing: 6) {
            StatusLine(bed: bed)
            StepperRow(title: "Head", value: bed.position(.head).map { "\($0)%" },
                       target: bed.desiredPosition[.head].map { "\($0)%" },
                       minus: { bed.nudge(.head, up: false) }, plus: { bed.nudge(.head, up: true) })
            if bed.hasFoot {
                StepperRow(title: "Foot", value: bed.position(.foot).map { "\($0)%" },
                           target: bed.desiredPosition[.foot].map { "\($0)%" },
                           minus: { bed.nudge(.foot, up: false) }, plus: { bed.nudge(.foot, up: true) })
            }
            if bed.isBusy {
                Button(role: .destructive, action: bed.stop) {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                HStack(spacing: 6) {
                    Button { bed.preset(.flat) } label: {
                        Label("Flat", systemImage: "bed.double").frame(maxWidth: .infinity)
                    }
                    Button { bed.preset(.favorite) } label: {
                        Label("Fav", systemImage: "star.fill").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, pageInset)
    }
}

private struct FirmnessView: View {
    let bed: BedController
    // Local view state so a tap redraws immediately. Observing bed.firmnessSide alone lagged
    // until some other change (e.g. the idle disconnect) forced this page to redraw.
    @State private var side: MCRSide?

    var body: some View {
        let side = self.side ?? bed.firmnessSide
        VStack(spacing: 8) {
            StatusLine(bed: bed)
            HStack(spacing: 6) {
                SideButton(title: "Left", selected: side == .left) { select(.left) }
                SideButton(title: "Right", selected: side == .right) { select(.right) }
            }
            StepperRow(title: "Firmness", value: bed.firmness(side).map { "\($0)" },
                       target: bed.desiredFirmness[side].map { "\($0)" },
                       minus: { bed.nudgeFirmness(up: false) }, plus: { bed.nudgeFirmness(up: true) })
            let other: MCRSide = side == .left ? .right : .left
            Text("\(other == .left ? "Left" : "Right") \(bed.firmness(other).map { "\($0)" } ?? "–")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, pageInset)
    }

    private func select(_ newSide: MCRSide) {
        side = newSide
        bed.selectFirmnessSide(newSide)
    }
}

private struct SideButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SideButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Selected side: solid accent fill. Other side: outline only, dimmed.
private struct SideButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(selected ? .bold : .regular))
            .foregroundStyle(selected ? Color.black : Color.secondary)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(selected ? Color.accentColor : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(selected ? Color.clear : Color.secondary, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct StepperRow: View {
    let title: String
    let value: String?
    let target: String?
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: minus) { Image(systemName: "minus").font(.title3.bold()) }
                .frame(width: 52, height: 52)
            VStack(spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value ?? "–").font(.title3.monospacedDigit().bold())
                if let target {
                    Text("→ \(target)").font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity)
            Button(action: plus) { Image(systemName: "plus").font(.title3.bold()) }
                .frame(width: 52, height: 52)
        }
    }
}

private struct StatusLine: View {
    let bed: BedController

    var body: some View {
        Group {
            switch bed.phase {
            case .idle: Text("Tap to connect").foregroundStyle(.secondary)
            case .connecting: Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
            case .ready: Label("Connected", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .working(let what): Label(what, systemImage: "arrow.triangle.2.circlepath")
            case .failed(let why): Text(why).foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.caption2)
        .onTapGesture { bed.refresh() }
    }
}
