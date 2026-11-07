// The weather complication needs location, but widgets can't show the permission prompt;
// the containing app has to ask. Asks once, then refreshes the widgets when access changes.

import CoreLocation
import WidgetKit

@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in WidgetCenter.shared.reloadAllTimelines() }
    }
}
