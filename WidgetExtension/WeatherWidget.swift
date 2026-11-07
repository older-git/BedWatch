// Temperature + relative humidity in a single complication slot. Data and location come from
// Shared/Weather.swift. Tapping opens BedWatch's Weather page (watchOS can't open Weather.app).

import SwiftUI
import WidgetKit

struct WeatherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TempHumidity", provider: WeatherProvider()) { entry in
            WeatherView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WeatherService.deepLink)
        }
        .configurationDisplayName("Temp + Humidity")
        .description("Current temperature and relative humidity in one slot.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct WeatherEntry: TimelineEntry {
    let date: Date
    let temperature: Double?
    let humidity: Int?
    let unit: String   // "°F" or "°C"

    static let placeholder = WeatherEntry(date: .now, temperature: 72, humidity: 45, unit: "°F")
    static let unavailable = WeatherEntry(date: .now, temperature: nil, humidity: nil, unit: "")

    var temperatureText: String { temperature.map { "\(Int($0.rounded()))°" } ?? "--°" }
    var humidityText: String { humidity.map { "\($0)%" } ?? "--%" }
}

struct WeatherProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeatherEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WeatherEntry) -> Void) {
        if context.isPreview { return completion(.placeholder) }
        // WidgetKit calls back on any thread; the handler is safe to call from the task.
        nonisolated(unsafe) let completion = completion
        Task { completion(await WeatherFetcher.current()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeatherEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            let entry = await WeatherFetcher.current()
            // Open-Meteo's "current" values update every 15 min; 30 min keeps within the
            // watchOS widget refresh budget.
            let next = Date.now.addingTimeInterval(entry.temperature == nil ? 10 * 60 : 30 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

enum WeatherFetcher {
    static func current() async -> WeatherEntry {
        do {
            let f = try await WeatherService.forecast()
            return WeatherEntry(date: .now, temperature: f.temperature, humidity: f.humidity, unit: f.unit)
        } catch {
            print("[weather] fetch failed: \(error)")
            return .unavailable
        }
    }
}

private struct WeatherView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeatherEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            // One line, "49% 66°", as large as the circle allows: start big and let it shrink
            // to fit the width rather than wrap.
            ZStack {
                AccessoryWidgetBackground()
                (Text(entry.humidityText).foregroundStyle(.cyan) + Text(" ") + Text(entry.temperatureText))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.horizontal, 3)
            }
        case .accessoryCorner:
            // Corner text only curves when the main Text has widgetCurvesContent() *and* a
            // widgetLabel is attached (without the label it renders straight and stacked).
            // The label is a humidity gauge rather than text, which looked like clutter.
            // Size: 30 pt overflowed the curved band ("..."); the system default looked small.
            Text("\(entry.humidityText)  \(entry.temperatureText)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: Double(entry.humidity ?? 0), in: 0...100) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinear)
                    .tint(.cyan)
                }
        case .accessoryRectangular:
            HStack(spacing: 10) {
                Label(entry.temperatureText, systemImage: "thermometer.medium")
                Label(entry.humidityText, systemImage: "drop.fill").foregroundStyle(.cyan)
            }
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        default:
            Text("\(entry.temperatureText) \(Image(systemName: "drop.fill"))\(entry.humidityText)")
        }
    }
}
