import SwiftUI
import WidgetKit

@main
struct BedWatchApp: App {
    private enum Screen { case remote, weather }

    @State private var bed = BedController()
    @State private var location = LocationPermission()
    @State private var screen = Screen.remote
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch screen {
                case .remote:
                    ContentView(bed: bed)
                case .weather:
                    WeatherPage(onRemote: {
                        screen = .remote
                        bed.refresh()
                    })
                }
            }
            .onOpenURL { url in
                guard url == WeatherService.deepLink else { return }
                // Opened from the weather complication: leave the bed (and its one BLE slot) alone.
                screen = .weather
                bed.release()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                location.requestIfNeeded()
                // Faces keep a cached drawing until the next scheduled refresh (up to 30 min);
                // opening the app redraws them, e.g. right after installing a new build.
                WidgetCenter.shared.reloadAllTimelines()
                // A complication tap delivers its URL just after activation; give it a moment
                // so a weather launch doesn't start a bed connection first.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if screen == .remote { bed.refresh() }
                }
            case .background:
                bed.release()
                screen = .remote
            default:
                break
            }
        }
    }
}
