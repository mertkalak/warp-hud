import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    var onMove: ((CGPoint) -> Void)?

    init<Content: View>(content: Content) {
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
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false

        let hosting = NSHostingView(rootView: content)
        contentView = hosting

        let size = hosting.fittingSize
        setContentSize(size)

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

    func updateDraggable(isPinned: Bool) {
        isMovableByWindowBackground = !isPinned
    }

    func position(relativeTo warpFrame: CGRect) {
        guard let contentView else { return }
        let size = contentView.fittingSize
        setContentSize(size)
        let x = warpFrame.maxX - size.width - 200
        let y = warpFrame.origin.y + 62
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func positionCustom(at point: CGPoint) {
        if let contentView {
            let size = contentView.fittingSize
            setContentSize(size)
        }
        setFrameOrigin(NSPoint(x: point.x, y: point.y))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func panelDidMove(_ notification: Notification) {
        onMove?(frame.origin)
    }
}
