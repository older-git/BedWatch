// Exposes "Bed to Favorite" to Shortcuts and Siri. (The Action button uses the control in
// WidgetExtension/BedWatchWidgets.swift: watchOS only offers user-built shortcuts there.)

import AppIntents

struct BedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecallFavoriteIntent(),
            phrases: [
                "Bed to favorite in \(.applicationName)",
                "\(.applicationName) favorite",
            ],
            shortTitle: "Bed Favorite",
            systemImageName: "star.fill"
        )
    }
}
