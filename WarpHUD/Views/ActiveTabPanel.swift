import AppKit
import SwiftUI

final class ActiveTabPanel: NSPanel {
    var onMove: ((CGPoint) -> Void)?
    private var hostingView: NSHostingView<ActiveTabView>

    init() {
        hostingView = NSHostingView(rootView: ActiveTabView(
            fullName: "",
            folderName: "",
            state: .idle,
            isPinned: true,
            onTogglePin: {}
        ))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false  // pin button needs clicks
        isMovableByWindowBackground = false
        contentView = hostingView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateContent(
        fullName: String,
        folderName: String,
        state: SessionState,
        isPinned: Bool,
        onTogglePin: @escaping () -> Void
    ) {
        hostingView.rootView = ActiveTabView(
            fullName: fullName,
            folderName: folderName,
            state: state,
            isPinned: isPinned,
            onTogglePin: onTogglePin
        )
        isMovableByWindowBackground = !isPinned
    }

    /// Position below the HUD, centered on the active tab's card.
    func positionBelow(hudFrame: CGRect, cardMidX: CGFloat) {
        let size = hostingView.fittingSize
        setContentSize(size)

        let x = hudFrame.origin.x + cardMidX - size.width / 2
        let y = hudFrame.origin.y - size.height - 4
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Position at a custom saved location.
    func positionCustom(at point: CGPoint) {
        let size = hostingView.fittingSize
        setContentSize(size)
        setFrameOrigin(NSPoint(x: point.x, y: point.y))
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    @objc private func panelDidMove(_ notification: Notification) {
        onMove?(frame.origin)
    }
}
