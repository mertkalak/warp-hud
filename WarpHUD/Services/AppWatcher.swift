import AppKit

final class AppWatcher {
    private(set) var isWarpFocused: Bool
    private let onFocusChange: (Bool) -> Void
    var onWarpQuit: (() -> Void)?
    private var focusObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init(onFocusChange: @escaping (Bool) -> Void) {
        self.onFocusChange = onFocusChange

        let app = NSWorkspace.shared.frontmostApplication
        isWarpFocused = Self.isWarp(app)

        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let focused = Self.isWarp(app)
            self.isWarpFocused = focused
            self.onFocusChange(focused)
        }

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            if Self.isWarp(app) {
                self.isWarpFocused = false
                self.onWarpQuit?()
            }
        }
    }

    deinit {
        if let o = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        if let o = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    private static func isWarp(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        return app.bundleIdentifier == "dev.warp.Warp-Stable"
            || app.bundleIdentifier == "dev.warp.Warp"
            || app.localizedName == "Warp"
            || app.localizedName == "stable"
    }
}
