import SwiftUI
import WidgetKit

@main
struct BedWatchWidgets: WidgetBundle {
    var body: some Widget {
        BedLauncherWidget()
        WeatherWidget()
    }
}

// MARK: - Bed launcher

/// One-tap shortcut to the remote from the watch face.
struct BedLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BedLauncher", provider: LauncherProvider()) { _ in
            LauncherView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bed Remote")
        .description("Opens BedWatch.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            // No label: a curved "Bed" sat off-center against the icon. The symbol alone fills
            // the corner bubble instead.
            Image(systemName: "bed.double.fill")
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .padding(2)
        case .accessoryInline:
            Label("Bed", systemImage: "bed.double.fill")
        case .accessoryRectangular:
            HStack {
                Image(systemName: "bed.double.fill").font(.system(size: 30, weight: .semibold))
                Text("Bed Remote").font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bed.double.fill").font(.system(size: 26, weight: .semibold))
                    .minimumScaleFactor(0.6)
            }
        }
    }
}
