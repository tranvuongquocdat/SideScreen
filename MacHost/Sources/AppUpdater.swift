import Cocoa
import Combine
import Sparkle

/// Sparkle auto-update, one instance for the whole app. Sparkle checks the
/// appcast once a day (SUScheduledCheckInterval) and asks before downloading;
/// nothing is installed without the user clicking through the dialog.
/// Builds without SUFeedURL in Info.plist (swift run, tests) never start it.
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var observation: AnyCancellable?

    private override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            debugLog("Sparkle: no SUFeedURL in Info.plist — update checks disabled (dev build)")
            return
        }
        controller.startUpdater()
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }
}

enum AppInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static let website = URL(string: "https://sidescreen.dev")!
    static let donate = URL(string: "https://sidescreen.dev/donate.html")!
    static let github = URL(string: "https://github.com/tranvuongquocdat/SideScreen")!
    static let changelog = URL(string: "https://github.com/tranvuongquocdat/SideScreen/blob/main/CHANGELOG.md")!
    static let reportProblem = URL(string: "https://github.com/tranvuongquocdat/SideScreen/issues/new/choose")!
}
