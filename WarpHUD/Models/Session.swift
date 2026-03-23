import Foundation

enum SessionState {
    case working   // TTY.active exists
    case waiting   // TTY.waiting exists
    case done      // TTY.done exists
    case idle      // none of the above
}

struct Session: Identifiable {
    let id: Int        // tab number (1-9)
    let name: String   // raw session name from file
    let tty: String?
    let state: SessionState
    let cwd: String?
    let isCurrentTab: Bool

    /// Last path component of the working directory, or "~" if unknown.
    var folderName: String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// Full name with leading symbols stripped (no truncation). Used by tooltip.
    var fullName: String {
        let clean = cleanedName
        return clean.isEmpty ? "Tab \(id)" : clean
    }

    /// Strip leading non-alphanumeric chars (spinner symbols), truncate to 10.
    var displayName: String {
        let clean = cleanedName
        if clean.isEmpty { return "Tab \(id)" }
        if clean.count > 10 {
            return String(clean.prefix(9)) + "\u{2026}"
        }
        return clean
    }

    private var cleanedName: String {
        var result = name
        while let first = result.unicodeScalars.first,
              !CharacterSet.alphanumerics.contains(first) {
            result.removeFirst()
        }
        return result
    }
}
