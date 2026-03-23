import Foundation
import Observation

@Observable
final class HUDState {
    var sessions: [Session] = []
    var hoveredTabId: Int? = nil
    var cardMidXs: [Int: CGFloat] = [:]

    var showActiveTabTooltip: Bool {
        didSet { UserDefaults.standard.set(showActiveTabTooltip, forKey: "hudShowTooltip") }
    }

    var showActiveTabIndicator: Bool {
        didSet { UserDefaults.standard.set(showActiveTabIndicator, forKey: "hudShowIndicator") }
    }

    var showResourceUsage: Bool {
        didSet { UserDefaults.standard.set(showResourceUsage, forKey: "hudShowResources") }
    }

    var quitWithWarp: Bool {
        didSet { UserDefaults.standard.set(quitWithWarp, forKey: "hudQuitWithWarp") }
    }

    @ObservationIgnored var onHoverChange: ((Int?) -> Void)?
    @ObservationIgnored var onTabClick: ((Int) -> Void)?
    @ObservationIgnored var onSettingsToggle: (() -> Void)?

    /// Update hover and fire the instant callback.
    func setHoveredTab(_ id: Int?) {
        hoveredTabId = id
        onHoverChange?(id)
    }

    var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: "hudPinned") }
    }

    var indicatorPinned: Bool {
        didSet { UserDefaults.standard.set(indicatorPinned, forKey: "hudIndicatorPinned") }
    }

    var indicatorPosition: CGPoint? {
        didSet {
            if let p = indicatorPosition {
                UserDefaults.standard.set(Double(p.x), forKey: "hudIndicatorX")
                UserDefaults.standard.set(Double(p.y), forKey: "hudIndicatorY")
            } else {
                UserDefaults.standard.removeObject(forKey: "hudIndicatorX")
                UserDefaults.standard.removeObject(forKey: "hudIndicatorY")
            }
        }
    }

    var customPosition: CGPoint? {
        didSet {
            if let p = customPosition {
                UserDefaults.standard.set(Double(p.x), forKey: "hudCustomX")
                UserDefaults.standard.set(Double(p.y), forKey: "hudCustomY")
            } else {
                UserDefaults.standard.removeObject(forKey: "hudCustomX")
                UserDefaults.standard.removeObject(forKey: "hudCustomY")
            }
        }
    }

    private let sessionDir: String

    init(sessionDir: String? = nil) {
        self.sessionDir = sessionDir ?? (NSHomeDirectory() + "/.claude-hud")

        // Restore persisted state
        let defaults = UserDefaults.standard
        // Default to pinned if key doesn't exist
        showActiveTabTooltip = defaults.object(forKey: "hudShowTooltip") == nil
            ? true  // on by default
            : defaults.bool(forKey: "hudShowTooltip")
        showActiveTabIndicator = defaults.bool(forKey: "hudShowIndicator")
        showResourceUsage = defaults.object(forKey: "hudShowResources") == nil
            ? true  // on by default
            : defaults.bool(forKey: "hudShowResources")
        quitWithWarp = defaults.object(forKey: "hudQuitWithWarp") == nil
            ? true  // on by default
            : defaults.bool(forKey: "hudQuitWithWarp")
        isPinned = defaults.object(forKey: "hudPinned") == nil
            ? true
            : defaults.bool(forKey: "hudPinned")
        indicatorPinned = defaults.object(forKey: "hudIndicatorPinned") == nil
            ? true
            : defaults.bool(forKey: "hudIndicatorPinned")

        if defaults.object(forKey: "hudIndicatorX") != nil {
            indicatorPosition = CGPoint(
                x: defaults.double(forKey: "hudIndicatorX"),
                y: defaults.double(forKey: "hudIndicatorY")
            )
        } else {
            indicatorPosition = nil
        }

        if defaults.object(forKey: "hudCustomX") != nil {
            customPosition = CGPoint(
                x: defaults.double(forKey: "hudCustomX"),
                y: defaults.double(forKey: "hudCustomY")
            )
        } else {
            customPosition = nil
        }
    }

    func togglePin() {
        isPinned.toggle()
    }

    func saveCustomPosition(_ point: CGPoint) {
        customPosition = point
    }

    /// Clean stale auxiliary files for tabs that don't have a session NAME file.
    func cleanStaleFiles() {
        let fm = FileManager.default
        let suffixes = [".tty", ".notify", ".avatar", ".nick", ".pos", ".lock"]
        for i in 1...9 {
            let namePath = sessionDir + "/\(i)"
            if !fm.fileExists(atPath: namePath) {
                for suffix in suffixes {
                    try? fm.removeItem(atPath: sessionDir + "/\(i)" + suffix)
                }
            }
        }
    }

    /// Re-read all session files from disk and rebuild the sessions array.
    func load() {
        let fm = FileManager.default
        let currentTab = readInt(at: sessionDir + "/current")

        var result: [Session] = []
        for i in 1...9 {
            var name = readLine(at: sessionDir + "/\(i)")
            let tty = readLine(at: sessionDir + "/\(i).tty")

            // Only show tabs with actual session NAME files (source of truth)
            guard let name, !name.isEmpty else { continue }

            let state: SessionState
            if let tty {
                if fm.fileExists(atPath: sessionDir + "/\(tty).waiting") {
                    state = .waiting
                } else if fm.fileExists(atPath: sessionDir + "/\(tty).active") {
                    state = .working
                } else if fm.fileExists(atPath: sessionDir + "/\(tty).done") {
                    state = .done
                } else {
                    state = .idle
                }
            } else {
                state = .idle
            }

            let cwd: String?
            if let tty {
                cwd = readLine(at: sessionDir + "/\(tty).cwd")
            } else {
                cwd = nil
            }

            result.append(Session(
                id: i,
                name: name,
                tty: tty,
                state: state,
                cwd: cwd,
                isCurrentTab: i == currentTab
            ))
        }

        sessions = result
    }

    // MARK: - File helpers

    private func readLine(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else { return nil }
        return str
    }

    private func readInt(at path: String) -> Int? {
        guard let str = readLine(at: path) else { return nil }
        return Int(str)
    }
}
