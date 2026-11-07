import SwiftUI

@main
struct BedWatchApp: App {
    private let bed = BedController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RecallFavoriteIntent.handler = { BedController.shared.preset(.favorite) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(bed: bed)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: bed.refresh()
            case .background: bed.release()
            default: break
            }
        }
    }
}
