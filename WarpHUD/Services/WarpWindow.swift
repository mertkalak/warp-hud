import AppKit

enum WarpWindow {
    /// Returns the frame of the main Warp window in Cocoa screen coordinates
    /// (origin at bottom-left of the main display).
    /// Picks the largest layer-0 Warp window to avoid toolbars/tab bars.
    static func frame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var bestRect: CGRect?
        var bestArea: CGFloat = 0

        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  owner == "Warp" || owner == "stable",
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            var cgRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &cgRect) else {
                continue
            }

            let area = cgRect.width * cgRect.height
            if area > bestArea {
                bestArea = area
                bestRect = cgRect
            }
        }

        guard let cgRect = bestRect else { return nil }

        // CG coordinates (top-left origin of the PRIMARY display) →
        // Cocoa global coordinates (bottom-left origin of the primary display).
        // NSScreen.main is the screen containing the key window — unreliable for
        // LSUIElement apps and on multi-monitor setups. We need the primary screen
        // (the one whose Cocoa frame.origin == .zero), which owns the menu bar
        // and anchors the CG coordinate space.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        let screenH = primary?.frame.height ?? 0
        return CGRect(
            x: cgRect.origin.x,
            y: screenH - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
