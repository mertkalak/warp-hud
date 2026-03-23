import AppKit
import CoreGraphics

/// Top-level C callback — CGEventTapCallBack can't reliably use Swift closures with refcon.
/// Uses KeyboardTap.shared singleton instead.
private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Re-enable tap if macOS disabled it (timeout protection)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = KeyboardTap.shared?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    if let tap = KeyboardTap.shared {
        if type == .keyDown {
            tap.handleKeyEvent(event)
        } else if type == .leftMouseDown {
            // Consume click if it hit the HUD (prevents Warp losing focus)
            if tap.handleMouseClick(event) {
                return nil
            }
        }
    }
    return Unmanaged.passUnretained(event)
}

final class KeyboardTap {
    // Keycodes from init.lua
    private static let digitKeycodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4,
        23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
    private static let keycodeT: UInt16 = 17
    private static let keycodeW: UInt16 = 13

    private static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", ""]
    private static let sessionDir = NSHomeDirectory() + "/.claude-hud"

    var onTabChanged: (() -> Void)?
    var onTabClick: ((Int) -> Void)?

    /// Updated by AppDelegate so click detection knows the HUD's screen position.
    var hudPanelFrame: CGRect = .zero
    /// Updated by AppDelegate — maps tab ID → midX in panel-local coords.
    var cardMidXs: [Int: CGFloat] = [:]

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Singleton for C callback access (CGEventTapCallBack can't capture context reliably)
    fileprivate static var shared: KeyboardTap?

    init() {}

    func start() {
        guard eventTap == nil else { return }
        KeyboardTap.shared = self

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: nil
        )

        guard let eventTap else {
            // tap creation failed
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        // tap ready
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: - Mouse click handling

    /// Returns true if the click was consumed (hit a tab card).
    @discardableResult
    fileprivate func handleMouseClick(_ event: CGEvent) -> Bool {
        guard !hudPanelFrame.isEmpty, !cardMidXs.isEmpty else { return false }

        let cgPoint = event.location
        let screenH = NSScreen.main?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: cgPoint.x, y: screenH - cgPoint.y)

        guard hudPanelFrame.contains(cocoaPoint) else { return false }

        let localX = cocoaPoint.x - hudPanelFrame.origin.x

        var bestTab: Int?
        var bestDist: CGFloat = 60

        for (tabId, midX) in cardMidXs {
            let dist = abs(localX - midX)
            if dist < bestDist {
                bestDist = dist
                bestTab = tabId
            }
        }

        if let tab = bestTab {
            DispatchQueue.main.async { self.onTabClick?(tab) }
            return true  // consumed
        }
        return false
    }

    // MARK: - Keyboard event handling

    fileprivate func handleKeyEvent(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Only Cmd (no shift, alt, ctrl)
        guard flags.contains(.maskCommand),
              !flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl) else { return }

        if let digit = Self.digitKeycodes[keyCode] {
            handleDigit(digit)
        } else if keyCode == Self.keycodeT {
            handleNewTab()
        } else if keyCode == Self.keycodeW {
            handleCloseTab()
        }
    }

    private func handleDigit(_ digit: Int) {
        let fm = FileManager.default
        let sessionPath = Self.sessionDir + "/\(digit)"

        if fm.fileExists(atPath: sessionPath) {
            // Existing tab: update current, clear waiting/done signals
            writeCurrentTab(digit)
            if let tty = readTTY(digit) {
                try? fm.removeItem(atPath: Self.sessionDir + "/\(tty).waiting")
                try? fm.removeItem(atPath: Self.sessionDir + "/\(tty).done")
            }
            notifyChanged()

            // Auto-learn tab name after 200ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                guard !isLocked(digit) else { return }
                if let title = getWarpTitle(), isMeaningfulTitle(title) {
                    let current = readSession(digit)
                    if current != title && !isGenericTitle(title) {
                        writeSession(digit, title)
                        notifyChanged()
                    }
                }
            }
        } else {
            // Unregistered tab: register it
            let previousTab = readCurrentTab()
            writeCurrentTab(digit)
            let titleBefore = getWarpTitle()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                let titleAfter = getWarpTitle()
                if titleAfter != nil && titleAfter != titleBefore {
                    for g in 1...digit {
                        if !FileManager.default.fileExists(atPath: Self.sessionDir + "/\(g)") {
                            writeSession(g, "Tab \(g)")
                        }
                    }
                    if let title = titleAfter, isMeaningfulTitle(title) {
                        writeSession(digit, title)
                    } else {
                        writeSession(digit, "Tab \(digit)")
                    }
                    notifyChanged()
                } else {
                    // Title didn't change — no such tab in Warp, restore previous
                    writeCurrentTab(previousTab)
                    notifyChanged()
                }
            }
        }
    }

    private func handleNewTab() {
        let currentTab = readCurrentTab() ?? 1
        let sessions = countSessions()
        let insertAt = (currentTab < sessions) ? currentTab + 1 : sessions + 1

        guard insertAt <= 9 else { return }

        // Shift higher tabs up
        if insertAt <= sessions && sessions < 9 {
            for i in stride(from: sessions, through: insertAt, by: -1) {
                shiftTab(from: i, to: i + 1)
            }
        }

        // Register new tab
        writeSession(insertAt, "Tab \(insertAt)")
        try? FileManager.default.removeItem(atPath: Self.sessionDir + "/\(insertAt).tty")
        try? FileManager.default.removeItem(atPath: Self.sessionDir + "/\(insertAt).lock")
        writeCurrentTab(insertAt)
        notifyChanged()

        // Poll for meaningful title
        let titleBefore = getWarpTitle()
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts += 1
            if let title = getWarpTitle(),
               title != titleBefore,
               isMeaningfulTitle(title) {
                timer.invalidate()
                writeSession(insertAt, title)
                notifyChanged()
            } else if attempts >= 30 {
                timer.invalidate()
            }
        }
    }

    private func handleCloseTab() {
        guard let closedTab = readCurrentTab() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            let fm = FileManager.default

            if let tty = readTTY(closedTab) {
                try? fm.removeItem(atPath: Self.sessionDir + "/\(tty).active")
                try? fm.removeItem(atPath: Self.sessionDir + "/\(tty).waiting")
                try? fm.removeItem(atPath: Self.sessionDir + "/\(tty).done")
                try? fm.removeItem(atPath: Self.sessionDir + "/\(tty).cwd")
            }

            for i in closedTab...8 {
                let nextPath = Self.sessionDir + "/\(i + 1)"
                if fm.fileExists(atPath: nextPath) {
                    if let name = readSession(i + 1) { writeSession(i, name) }
                    if let tty = readTTY(i + 1) {
                        try? tty.write(toFile: Self.sessionDir + "/\(i).tty", atomically: true, encoding: .utf8)
                    } else {
                        try? fm.removeItem(atPath: Self.sessionDir + "/\(i).tty")
                    }
                    setLock(i, isLocked(i + 1))
                } else {
                    try? fm.removeItem(atPath: Self.sessionDir + "/\(i)")
                    try? fm.removeItem(atPath: Self.sessionDir + "/\(i).tty")
                    setLock(i, false)
                }
            }
            try? fm.removeItem(atPath: Self.sessionDir + "/9")
            try? fm.removeItem(atPath: Self.sessionDir + "/9.tty")
            setLock(9, false)

            if !fm.fileExists(atPath: Self.sessionDir + "/\(closedTab)") && closedTab > 1 {
                writeCurrentTab(closedTab - 1)
            }
            notifyChanged()
        }
    }

    // MARK: - File helpers

    private func notifyChanged() {
        DispatchQueue.main.async { self.onTabChanged?() }
    }

    private func readSession(_ num: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: Self.sessionDir + "/\(num)"),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else { return nil }
        return str
    }

    private func writeSession(_ num: Int, _ name: String) {
        try? name.write(toFile: Self.sessionDir + "/\(num)", atomically: true, encoding: .utf8)
    }

    private func readTTY(_ num: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: Self.sessionDir + "/\(num).tty"),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else { return nil }
        return str
    }

    private func readCurrentTab() -> Int? {
        guard let data = FileManager.default.contents(atPath: Self.sessionDir + "/current"),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let num = Int(str) else { return nil }
        return num
    }

    private func writeCurrentTab(_ num: Int?) {
        let path = Self.sessionDir + "/current"
        if let num {
            try? String(num).write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func isLocked(_ num: Int) -> Bool {
        FileManager.default.fileExists(atPath: Self.sessionDir + "/\(num).lock")
    }

    private func setLock(_ num: Int, _ locked: Bool) {
        let path = Self.sessionDir + "/\(num).lock"
        if locked {
            try? "1".write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func countSessions() -> Int {
        var count = 0
        for i in 1...9 {
            if FileManager.default.fileExists(atPath: Self.sessionDir + "/\(i)") {
                count = i
            } else {
                break
            }
        }
        return count
    }

    private func shiftTab(from: Int, to: Int) {
        if let name = readSession(from) { writeSession(to, name) }
        if let tty = readTTY(from) {
            try? tty.write(toFile: Self.sessionDir + "/\(to).tty", atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: Self.sessionDir + "/\(to).tty")
        }
        setLock(to, isLocked(from))
    }

    private func getWarpTitle() -> String? {
        // Use NSWorkspace to find Warp, then CGWindowList for title
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Find the largest Warp window at layer 0 (main window, not toolbar)
        var bestName: String?
        var bestArea: CGFloat = 0

        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  owner == "Warp" || owner == "stable",
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary else { continue }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) else { continue }
            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                bestName = entry[kCGWindowName as String] as? String
            }
        }
        return bestName
    }

    private func isMeaningfulTitle(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let first = title.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return !Self.shellNames.contains(first)
    }

    private func isGenericTitle(_ title: String) -> Bool {
        let clean = title.replacingOccurrences(of: "^[^a-zA-Z0-9]+", with: "", options: .regularExpression).lowercased()
        return clean == "claude code" || clean == "claude"
    }
}
