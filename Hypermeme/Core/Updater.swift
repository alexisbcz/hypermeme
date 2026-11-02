import Sparkle

/// Checks GitHub releases for new versions. Off in Debug builds, which aren't released.
final class Updater {
    static let shared = Updater()

    #if DEBUG
    private static let isEnabled = false
    #else
    private static let isEnabled = true
    #endif

    private let controller = SPUStandardUpdaterController(startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: nil)

    func check() {
        guard Self.isEnabled else { return }
        controller.updater.checkForUpdates()
    }
}
