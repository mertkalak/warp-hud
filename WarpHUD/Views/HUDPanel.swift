import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    var onMove: ((CGPoint) -> Void)?
    private var isDraggable = false
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?

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
        isDraggable = !isPinned
    }

    // Manual drag: NSHostingView consumes all mouse events, so
    // isMovableByWindowBackground never fires. Intercept in sendEvent
    // before SwiftUI, then forward so clicks/hover still work.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if isDraggable {
                dragStartMouseLocation = NSEvent.mouseLocation
                dragStartOrigin = frame.origin
            }
        case .leftMouseDragged:
            if isDraggable,
               let startMouse = dragStartMouseLocation,
               let startOrigin = dragStartOrigin {
                let current = NSEvent.mouseLocation
                let newOrigin = NSPoint(
                    x: startOrigin.x + (current.x - startMouse.x),
                    y: startOrigin.y + (current.y - startMouse.y)
                )
                setFrameOrigin(newOrigin)
            }
        case .leftMouseUp:
            dragStartMouseLocation = nil
            dragStartOrigin = nil
        default:
            break
        }
        super.sendEvent(event)
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
