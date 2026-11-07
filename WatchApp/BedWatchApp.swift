import SwiftUI

@main
struct BedWatchApp: App {
    @State private var bed = BedController()
    @Environment(\.scenePhase) private var scenePhase

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
