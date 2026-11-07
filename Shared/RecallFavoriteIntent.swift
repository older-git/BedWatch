// "Bed to Favorite": the action behind the Action button control, Shortcuts and Siri.
//
// Compiled into both the app and the widget extension (the control lives in the extension),
// but it only does anything in the app: it opens the app, and the app installs `handler`,
// which owns the Bluetooth connection.

import AppIntents

struct RecallFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Bed to Favorite"
    static let description = IntentDescription("Moves the bed to its Favorite position.")

    // Run in the foreground: connecting and moving takes longer than a background intent can
    // count on, and the open app shows progress and a Stop button.
    static let openAppWhenRun = true

    /// Set by the app at launch; nil inside the widget extension.
    @MainActor static var handler: (() -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.handler?()
        return .result()
    }
}
