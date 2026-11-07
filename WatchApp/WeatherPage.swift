// Opened by tapping the Temp + Humidity complication (watchOS can't hand off to Weather.app).

import SwiftUI

struct WeatherPage: View {
    let onRemote: () -> Void

    @State private var forecast: Forecast?
    @State private var failure: String?

    var body: some View {
        Group {
            if let forecast, forecast.isDontAsk {
                DontAsk()
                    .onTapGesture(perform: onRemote)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        if let forecast {
                            Current(forecast: forecast)
                            Hourly(forecast: forecast)
                            Text("Updated \(forecast.fetched.formatted(date: .omitted, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            // Open-Meteo's data is CC BY 4.0 and its terms require attribution.
                            Text("Weather data by Open-Meteo.com")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if let failure {
                            Text(failure).font(.footnote).multilineTextAlignment(.center)
                            Button("Retry") { Task { await load() } }
                        } else {
                            ProgressView("Weather…").padding(.top, 30)
                        }
                        Button(action: onRemote) {
                            Label("Bed Remote", systemImage: "bed.double.fill")
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .task { await load() }
    }

    /// Show the last forecast immediately (its "Updated" time shows its age), then refresh.
    private func load() async {
        failure = nil
        if forecast == nil { forecast = WeatherService.cached }
        do {
            forecast = try await WeatherService.forecast()
        } catch {
            if forecast == nil { failure = "\(error)" }
        }
    }
}

private struct Current: View {
    let forecast: Forecast

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Int(forecast.temperature.rounded()))°")
                .font(.system(size: 56, weight: .bold, design: .rounded))
            Label("\(forecast.humidity)%", systemImage: "drop.fill")
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.cyan)
            Text("H \(Int(forecast.high.rounded()))°   L \(Int(forecast.low.rounded()))°")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct Hourly: View {
    let forecast: Forecast

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(forecast.hours.enumerated()), id: \.element.id) { index, hour in
                HStack {
                    Text(index == 0 ? "Now" : hour.time.formatted(.dateTime.hour()))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(hour.temperature.rounded()))°")
                        .fontWeight(.semibold)
                }
                .font(.system(.title3, design: .rounded).monospacedDigit())
            }
        }
        .padding(.top, 6)
        // Extra inset so each hour sits close to its temperature and the rows are easy to scan.
        .padding(.horizontal, 28)
    }
}

/// Above 110 °F.
private struct DontAsk: View {
    var body: some View {
        ZStack {
            Color.red.ignoresSafeArea()
            Text("Don't ask...")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding()
        }
    }
}
