import AppKit
import SwiftUI

final class TooltipPanel: NSPanel {
    private var hostingView: NSHostingView<TooltipView>

    init() {
        hostingView = NSHostingView(rootView: TooltipView(text: ""))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the tooltip centered on `anchorScreenX`, 2px below `hudPanelFrame`.
    func show(text: String, anchorScreenX: CGFloat, hudPanelFrame: CGRect) {
        hostingView.rootView = TooltipView(text: text)
        let size = hostingView.fittingSize
        setContentSize(size)

        let x = anchorScreenX - size.width / 2
        let y = hudPanelFrame.origin.y - size.height - 2
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
