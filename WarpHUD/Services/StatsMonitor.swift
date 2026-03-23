import Foundation
import Observation

@Observable
final class StatsMonitor {
    var cpuText: String = "–"
    var ramText: String = "–"
    var cpuValue: Double = 0

    private var timer: Timer?
    private let pid: Int32

    init() {
        pid = ProcessInfo.processInfo.processIdentifier
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func sample() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pcpu=,rss=", "-p", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return
        }

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            // Parse "  4.2 12345" → cpu=4.2, rss=12345 (KB)
            let parts = output.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let cpu = Double(parts[0]),
                  let rssKB = Double(parts[1]) else { return }

            let rssMB = rssKB / 1024.0
            let ramStr: String
            if rssMB >= 1024 {
                ramStr = String(format: "%.1fG", rssMB / 1024.0)
            } else {
                ramStr = String(format: "%.0fM", rssMB)
            }

            DispatchQueue.main.async {
                self.cpuValue = cpu
                self.cpuText = String(format: "%.1f%%", cpu)
                self.ramText = ramStr
            }
        }
    }
}
