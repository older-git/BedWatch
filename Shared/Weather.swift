// Weather shared by the complication and the in-app Weather page.
//
// Data: Open-Meteo (free, no key). Location: the watch's current location, rounded to two
// decimals (~1 km) before it leaves the device; the last good fix is cached so a failed
// location lookup still shows weather for the last known place.

import CoreLocation
import Foundation

struct Forecast: Sendable, Codable {
    struct Hour: Sendable, Codable, Identifiable {
        let time: Date
        let temperature: Double
        var id: Date { time }
    }

    let fetched: Date
    let temperature: Double
    let humidity: Int
    let high: Double
    let low: Double
    let hours: [Hour]        // upcoming hours, starting with the current one
    let fahrenheit: Bool

    var unit: String { fahrenheit ? "°F" : "°C" }

    /// Above 110 °F (43.3 °C) the app stops pretending to be helpful.
    var isDontAsk: Bool {
        (fahrenheit ? temperature : temperature * 9 / 5 + 32) > 110
    }
}

enum WeatherService {
    static let deepLink = URL(string: "bedwatch://weather")!
    private static let cacheKey = "lastForecast"

    /// Last successful forecast (each target keeps its own), for showing something instantly
    /// while a fresh one loads. Ignored once older than 3 hours.
    static var cached: Forecast? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let forecast = try? JSONDecoder().decode(Forecast.self, from: data),
              forecast.fetched.timeIntervalSinceNow > -3 * 3600 else { return nil }
        return forecast
    }

    static func forecast() async throws -> Forecast {
        guard let coordinate = await WeatherLocation.coordinate() else { throw WeatherError.noLocation }
        let fahrenheit = Locale.current.measurementSystem == .us
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m"),
            .init(name: "hourly", value: "temperature_2m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        let reply = try JSONDecoder().decode(Reply.self, from: data)

        // Hourly times are local wall-clock strings ("2026-11-06T16:00") in the location's zone.
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        parser.timeZone = TimeZone(secondsFromGMT: reply.utc_offset_seconds)
        let startOfHour = Date.now.addingTimeInterval(-3600)
        let hours = zip(reply.hourly.time, reply.hourly.temperature_2m)
            .compactMap { time, temp in parser.date(from: time).map { Forecast.Hour(time: $0, temperature: temp) } }
            .filter { $0.time > startOfHour }
            .prefix(12)

        let forecast = Forecast(
            fetched: .now,
            temperature: reply.current.temperature_2m,
            humidity: Int(reply.current.relative_humidity_2m.rounded()),
            high: reply.daily.temperature_2m_max.first ?? reply.current.temperature_2m,
            low: reply.daily.temperature_2m_min.first ?? reply.current.temperature_2m,
            hours: Array(hours),
            fahrenheit: fahrenheit
        )
        if let data = try? JSONEncoder().encode(forecast) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return forecast
    }

    private struct Reply: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let relative_humidity_2m: Double
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }
}

enum WeatherError: Error, CustomStringConvertible {
    case noLocation

    var description: String { "Location unavailable. Allow location for BedWatch in Settings." }
}

enum WeatherLocation {
    private static let cacheKey = "lastCoordinate"

    static func coordinate() async -> CLLocationCoordinate2D? {
        if let fix = await OneShotLocation().fix() {
            UserDefaults.standard.set([fix.latitude, fix.longitude], forKey: cacheKey)
            return fix
        }
        guard let cached = UserDefaults.standard.array(forKey: cacheKey) as? [Double], cached.count == 2 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: cached[0], longitude: cached[1])
    }
}

/// A single coarse location fix with a timeout. Widgets can't prompt for permission; the app
/// asks on first launch.
@MainActor
private final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func fix() async -> CLLocationCoordinate2D? {
        // watchOS has no isAuthorizedForWidgetUpdates; the extension shares the app's grant.
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            print("[weather] location not authorized (\(status.rawValue))")
            return nil
        }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -15 * 60 {
            return recent.coordinate
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return await withCheckedContinuation { cont in
            continuation = cont
            manager.requestLocation()
            Task {
                try? await Task.sleep(for: .seconds(15))
                self.finish(nil)
            }
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in self.finish(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[weather] location failed: \(error)")
        Task { @MainActor in self.finish(nil) }
    }
}
