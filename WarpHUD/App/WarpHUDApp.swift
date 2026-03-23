import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: HUDPanel!
    private var tooltipPanel: TooltipPanel!
    private var settingsPanel: SettingsPanel!
    private var activeTabPanel: ActiveTabPanel!
    private var hudState: HUDState!
    private var statsMonitor: StatsMonitor!
    private var appWatcher: AppWatcher!
    private var keyboardTap: KeyboardTap!
    private var refreshTimer: Timer?
    private var isProgrammaticMove = false
    private var isIndicatorProgrammaticMove = false
    private var settingsVisible = false
    private var settingsLastClosed: Date = .distantPast
    private var hotkeyMonitor: Any?
    private var isDragging = false
    private var dragDebounce: Timer?

    private let digitKeycodes: [Int: CGKeyCode] = [
        1: 18, 2: 19, 3: 20, 4: 21,
        5: 23, 6: 22, 7: 26, 8: 28, 9: 25,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        hudState = HUDState()
        statsMonitor = StatsMonitor()
        hudState.cleanStaleFiles()
        hudState.load()
        // startup complete

        let contentView = HUDView(state: hudState, statsMonitor: statsMonitor)
        panel = HUDPanel(content: contentView)
        tooltipPanel = TooltipPanel()
        activeTabPanel = ActiveTabPanel()

        settingsPanel = SettingsPanel(state: hudState, onClose: { [weak self] in
            self?.hideSettings()
        })

        // HUD pin/drag
        panel.updateDraggable(isPinned: hudState.isPinned)
        panel.onMove = { [weak self] origin in
            guard let self, !self.isProgrammaticMove else { return }
            self.hudState.saveCustomPosition(origin)
            // Hide tooltip/indicator during drag, debounce re-show
            self.isDragging = true
            self.tooltipPanel.hide()
            self.activeTabPanel.hide()
            self.dragDebounce?.invalidate()
            self.dragDebounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                self.isDragging = false
                self.updateTooltip()
                self.updateActiveTabIndicator()
            }
        }

        // Indicator pin/drag
        activeTabPanel.onMove = { [weak self] origin in
            guard let self, !self.isIndicatorProgrammaticMove else { return }
            self.hudState.indicatorPosition = origin
        }

        // Instant tooltip on hover
        hudState.onHoverChange = { [weak self] _ in
            self?.updateTooltip()
        }

        // Tab click → switch in Warp
        hudState.onTabClick = { [weak self] num in
            self?.switchToTab(num)
        }

        // Settings gear toggle
        hudState.onSettingsToggle = { [weak self] in
            self?.toggleSettings()
        }

        // Keyboard tap: Cmd+digit/T/W detection + click-to-switch (Phase 3)
        keyboardTap = KeyboardTap()
        keyboardTap.onTabChanged = { [weak self] in
            self?.hudState.load()
            self?.showPanel()
        }
        keyboardTap.onTabClick = { [weak self] num in
            self?.switchToTab(num)
        }

        appWatcher = AppWatcher { [weak self] warpFocused in
            self?.handleFocusChange(warpFocused: warpFocused)
        }
        appWatcher.onWarpQuit = { [weak self] in
            guard let self, self.hudState.quitWithWarp else { return }
            NSApplication.shared.terminate(nil)
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        setupHotkeys()

        // Start keyboard tap once (stays running — listenOnly is low overhead)
        keyboardTap.start()

        if appWatcher.isWarpFocused {
            showPanel()
        }
    }

    // MARK: - Panel management

    private func handleFocusChange(warpFocused: Bool) {
        if warpFocused {
            hudState.load()
            showPanel()
        } else {
            panel.orderOut(nil)
            tooltipPanel.hide()
            activeTabPanel.hide()
            hideSettings()
        }
    }

    private func refresh() {
        hudState.load()
        guard appWatcher.isWarpFocused, !hudState.sessions.isEmpty else {
            panel.orderOut(nil)
            tooltipPanel.hide()
            activeTabPanel.hide()
            hideSettings()
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard !hudState.sessions.isEmpty else {
            panel.orderOut(nil)
            tooltipPanel.hide()
            activeTabPanel.hide()
            hideSettings()
            return
        }

        let size = panel.contentView?.fittingSize ?? .zero

        if let pos = hudState.customPosition {
            let newFrame = NSRect(origin: pos, size: size)
            if panel.frame != newFrame {
                isProgrammaticMove = true
                panel.setFrame(newFrame, display: true)
                isProgrammaticMove = false
            }
        } else if let warpFrame = WarpWindow.frame() {
            isProgrammaticMove = true
            panel.position(relativeTo: warpFrame)
            isProgrammaticMove = false
            hudState.saveCustomPosition(panel.frame.origin)
        } else {
            panel.orderOut(nil)
            tooltipPanel.hide()
            activeTabPanel.hide()
            hideSettings()
            return
        }

        panel.updateDraggable(isPinned: hudState.isPinned)
        panel.orderFrontRegardless()

        // Feed panel position to keyboard tap for click detection
        keyboardTap.hudPanelFrame = panel.frame
        keyboardTap.cardMidXs = hudState.cardMidXs

        updateTooltip()
        updateActiveTabIndicator()
    }

    // MARK: - Tooltip (always shows current tab's full name; hover overrides)

    private func updateTooltip() {
        guard !isDragging else { return }
        // If hovering a tab, show that tab's full name
        if let hoveredId = hudState.hoveredTabId,
           let session = hudState.sessions.first(where: { $0.id == hoveredId }),
           let midX = hudState.cardMidXs[hoveredId] {
            let screenX = panel.frame.origin.x + midX
            tooltipPanel.show(text: session.fullName, anchorScreenX: screenX, hudPanelFrame: panel.frame)
            return
        }

        // No hover — show current tab's full name if tooltip toggle is on
        if hudState.showActiveTabTooltip,
           let current = hudState.sessions.first(where: { $0.isCurrentTab }),
           let midX = hudState.cardMidXs[current.id] {
            let screenX = panel.frame.origin.x + midX
            tooltipPanel.show(text: current.fullName, anchorScreenX: screenX, hudPanelFrame: panel.frame)
            return
        }

        tooltipPanel.hide()
    }

    // MARK: - Active tab indicator

    private func updateActiveTabIndicator() {
        guard !isDragging else { return }
        guard hudState.showActiveTabIndicator,
              let session = hudState.sessions.first(where: { $0.isCurrentTab }) else {
            activeTabPanel.hide()
            return
        }

        activeTabPanel.updateContent(
            fullName: session.fullName,
            folderName: session.folderName,
            state: session.state,
            isPinned: hudState.indicatorPinned,
            onTogglePin: { [weak self] in
                self?.hudState.indicatorPinned.toggle()
                self?.updateActiveTabIndicator()
            }
        )

        if let pos = hudState.indicatorPosition {
            // Use saved position — indicator is independent of HUD
            isIndicatorProgrammaticMove = true
            activeTabPanel.positionCustom(at: pos)
            isIndicatorProgrammaticMove = false
        } else {
            // Initial placement: use init.lua's left indicator position
            // (420px from left, 82px from bottom of Warp window)
            if let warpFrame = WarpWindow.frame() {
                let x = warpFrame.origin.x + 420
                let y = warpFrame.origin.y + 82
                isIndicatorProgrammaticMove = true
                activeTabPanel.positionCustom(at: CGPoint(x: x, y: y))
                isIndicatorProgrammaticMove = false
                hudState.indicatorPosition = activeTabPanel.frame.origin
            }
        }

        activeTabPanel.show()
    }

    // MARK: - Tab switching

    private func switchToTab(_ num: Int) {
        // Optimistic HUD update
        let currentPath = NSHomeDirectory() + "/.claude-hud/current"
        try? String(num).write(toFile: currentPath, atomically: true, encoding: .utf8)
        hudState.load()

        // Activate Warp first
        NSRunningApplication.runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable")
            .first?.activate()

        // Post Cmd+digit after Warp is frontmost
        guard let keycode = digitKeycodes[num] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .combinedSessionState)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cgSessionEventTap)
                keyUp.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Click monitor: detects clicks on tab cards by checking against cardMidXs positions.
    /// Runs at the app level so it works regardless of isMovableByWindowBackground.
    // Click-to-switch is handled by KeyboardTap's global CGEvent mouse tap

    // MARK: - Settings

    private func toggleSettings() {
        if settingsVisible {
            hideSettings()
        } else {
            // Don't reopen if just closed by click-outside (which also triggers gear tap)
            guard Date().timeIntervalSince(settingsLastClosed) > 0.2 else { return }
            settingsPanel.show(relativeTo: panel.frame)
            settingsVisible = true
        }
    }

    private func hideSettings() {
        guard settingsVisible else { return }
        settingsPanel.hide()
        settingsVisible = false
        settingsLastClosed = Date()
    }

    // MARK: - Global hotkeys (Cmd+Ctrl+W: clear, Cmd+Ctrl+R: reload)

    private func setupHotkeys() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains([.command, .control]) else { return }
            switch event.keyCode {
            case 15: // R
                DispatchQueue.main.async { self?.relaunchApp() }
            case 13: // W
                DispatchQueue.main.async { self?.clearSessions() }
            default:
                break
            }
        }
    }

    private func clearSessions() {
        let dir = NSHomeDirectory() + "/.claude-hud"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for file in files {
            // Remove session files (1-9), .tty, .lock, .active, .waiting, .done, .cwd, current
            let path = dir + "/" + file
            if file == "current"
                || file.range(of: #"^\d+$"#, options: .regularExpression) != nil
                || file.hasSuffix(".tty") || file.hasSuffix(".lock")
                || file.hasSuffix(".active") || file.hasSuffix(".waiting")
                || file.hasSuffix(".done") || file.hasSuffix(".cwd") {
                try? fm.removeItem(atPath: path)
            }
        }
        hudState.load()
    }

    private func relaunchApp() {
        let appPath = "/Applications/WarpHUD.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [appPath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}

@main
enum WarpHUDApp {
    nonisolated(unsafe) static var appDelegate: AppDelegate?

    static func main() {
        // Single-instance guard: exit if another WarpHUD is already running
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.warphud.app")
        if running.contains(where: { $0.processIdentifier != currentPID }) {
            exit(0)
        }
        // Also check by process name for unbundled debug builds
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "WarpHUD" && $0.processIdentifier != currentPID
        }
        if !others.isEmpty {
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
