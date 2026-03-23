import AppKit
import SwiftUI

final class SettingsPanel: NSPanel {
    var onClose: (() -> Void)?
    private var clickMonitor: Any?

    init(state: HUDState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let hosting = NSHostingView(rootView: SettingsView(state: state, onClose: onClose))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show relative to HUD, position-aware (above if near screen bottom).
    func show(relativeTo hudFrame: CGRect) {
        guard let hosting = contentView as? NSHostingView<SettingsView> else { return }
        let size = hosting.fittingSize
        setContentSize(size)

        let x = hudFrame.maxX - size.width

        // Check if below would overflow screen
        let screenBottom = NSScreen.main?.visibleFrame.origin.y ?? 0
        let yBelow = hudFrame.origin.y - size.height - 4
        let yAbove = hudFrame.maxY + 4

        let y = yBelow >= screenBottom ? yBelow : yAbove
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()

        // Click-outside-to-dismiss
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let loc = event.locationInWindow
            // If the click is in a different window or outside our frame
            if event.window !== self {
                self.onClose?()
            } else {
                let localPoint = self.contentView?.convert(loc, from: nil) ?? loc
                if let contentView = self.contentView,
                   !contentView.bounds.contains(localPoint) {
                    self.onClose?()
                }
            }
            return event
        }
    }

    func hide() {
        orderOut(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
