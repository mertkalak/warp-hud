import AppKit
import Foundation

/// Periodically discovers shell CWDs via lsof for all registered TTYs.
/// Also discovers and assigns TTYs to tabs that don't have them yet.
/// Mirrors Hammerspoon's refreshCWDs() (init.lua:150-209).
final class CWDResolver {
    private let sessionDir: String
    private var timer: Timer?

    init(sessionDir: String? = nil) {
        self.sessionDir = sessionDir ?? (NSHomeDirectory() + "/.claude-hud")
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let fm = FileManager.default

        // Step 1: Discover TTYs for tabs that don't have them
        discoverMissingTTYs(fm: fm)

        // Step 2: Collect all known TTYs and resolve CWDs via lsof
        var ttys: [String] = []
        for i in 1...9 {
            guard let data = fm.contents(atPath: sessionDir + "/\(i).tty"),
                  let tty = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !tty.isEmpty else { continue }
            ttys.append(tty)
        }

        guard !ttys.isEmpty else { return }

        // Build batched shell script matching init.lua:159-168
        let cmds = ttys.map { tty in
            "pid=$(ps -t \(tty) -o pid=,comm= 2>/dev/null | awk '$2~/-?(zsh|bash|fish)$/{print $1; exit}'); "
            + "if [ -n \"$pid\" ]; then cwd=$(lsof -a -p \"$pid\" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2)}'); "
            + "echo \"\(tty):$cwd\"; fi"
        }
        let script = cmds.joined(separator: "\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return
        }

        let sessionDir = self.sessionDir
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let stdout = String(data: data, encoding: .utf8) else { return }

            let now = Date()
            let fm = FileManager.default

            for line in stdout.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let tty = String(parts[0])
                let cwd = String(parts[1])
                guard !cwd.isEmpty else { continue }

                let cwdPath = sessionDir + "/\(tty).cwd"

                // If hook-written .cwd exists and is recent (< 1 hour), skip —
                // hook value is more accurate for Claude projects (init.lua:184-201)
                if let attrs = try? fm.attributesOfItem(atPath: cwdPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   now.timeIntervalSince(modDate) < 3600 {
                    continue
                }

                try? cwd.write(toFile: cwdPath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Find tabs with session names but no .tty file, then discover
    /// Warp-owned shell TTYs and assign unassigned ones to those tabs.
    private func discoverMissingTTYs(fm: FileManager) {
        // Find tabs needing TTY assignment
        var tabsNeedingTTY: [Int] = []
        var assignedTTYs: Set<String> = []

        for i in 1...9 {
            let namePath = sessionDir + "/\(i)"
            let ttyPath = sessionDir + "/\(i).tty"

            guard fm.fileExists(atPath: namePath) else { continue }

            if let data = fm.contents(atPath: ttyPath),
               let tty = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tty.isEmpty {
                assignedTTYs.insert(tty)
            } else {
                tabsNeedingTTY.append(i)
            }
        }

        guard !tabsNeedingTTY.isEmpty else { return }

        // Find all Warp-related PIDs (main + child processes)
        let warpPIDs = findWarpPIDs()
        guard !warpPIDs.isEmpty else { return }

        // Build awk filter matching any Warp PID
        let pidList = warpPIDs.map(String.init).joined(separator: " ")

        // Discover Warp-owned shell TTYs via ps
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c",
            "ps -eo tty,ppid,comm | awk -v pids='\(pidList)' "
            + "'BEGIN{n=split(pids,a,\" \"); for(i=1;i<=n;i++) p[a[i]]=1} "
            + "$3~/-?(zsh|bash|fish)$/ && ($2 in p) {print $1}'"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }

        guard process.terminationStatus == 0 else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let stdout = String(data: data, encoding: .utf8) else { return }

        // Filter to unassigned TTYs, sorted numerically
        let warpTTYs = stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !assignedTTYs.contains($0) }
            .sorted()

        // Assign in order: lowest unassigned TTY → lowest tab needing TTY
        for (tab, tty) in zip(tabsNeedingTTY, warpTTYs) {
            try? tty.write(
                toFile: sessionDir + "/\(tab).tty",
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Returns all Warp-related PIDs (main app + child processes).
    /// Warp uses a two-process architecture: main → child → shells.
    private func findWarpPIDs() -> [pid_t] {
        var pids: [pid_t] = []

        let bundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        for id in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                pids.append(app.processIdentifier)
            }
        }
        guard !pids.isEmpty else { return [] }

        // Also find direct child processes via ps
        // (shells are parented to Warp's child process, not the main one)
        let pidFilter = pids.map(String.init).joined(separator: "|")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c",
            "ps -eo pid,ppid | awk '$2~/^(\(pidFilter))$/ {print $1}'"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return pids }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.split(separator: "\n") {
                if let childPID = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                    pids.append(childPID)
                }
            }
        }

        return pids
    }
}
