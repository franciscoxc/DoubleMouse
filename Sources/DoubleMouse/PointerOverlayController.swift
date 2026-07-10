import AppKit

final class PointerOverlayController {
    private let window: NSWindow
    private let pointerView: PointerView

    var secondaryPointerPosition: CGPoint = CGPoint(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 300) {
        didSet {
            pointerView.secondaryPointerPosition = secondaryPointerPosition
        }
    }

    init() {
        let frame = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }

        pointerView = PointerView(frame: frame)
        pointerView.secondaryPointerPosition = secondaryPointerPosition

        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = pointerView
    }

    func show() {
        window.orderFrontRegardless()
    }

    func moveSecondaryBy(_ delta: CGPoint) {
        secondaryPointerPosition = clampedPoint(
            CGPoint(x: secondaryPointerPosition.x + delta.x, y: secondaryPointerPosition.y - delta.y)
        )
    }

    func pulseSecondary() {
        pointerView.pulseSecondary()
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        let frame = window.frame
        return CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX),
            y: min(max(point.y, frame.minY), frame.maxY)
        )
    }
}

final class PointerView: NSView {
    var secondaryPointerPosition: CGPoint = .zero {
        didSet { needsDisplay = true }
    }

    private var secondaryPulseUntil: Date?
    private let cursorImage = NSCursor.arrow.image
    private lazy var blueCursorImage = tintedCursorImage(color: .systemBlue)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawPointerImage(blueCursorImage, at: secondaryPointerPosition, mirrored: true)
        drawPulseIfNeeded(at: secondaryPointerPosition, color: .systemBlue, until: secondaryPulseUntil)
    }

    func pulseSecondary() {
        secondaryPulseUntil = Date().addingTimeInterval(0.35)
        needsDisplay = true
    }

    private func drawPulseIfNeeded(at point: CGPoint, color: NSColor, until pulseUntil: Date?) {
        guard let pulseUntil, pulseUntil > Date() else {
            return
        }

        let remaining = pulseUntil.timeIntervalSinceNow
        let progress = 1.0 - min(max(remaining / 0.35, 0), 1)
        drawPulse(at: point, color: color, progress: progress)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.needsDisplay = true
        }
    }

    private func drawPointerImage(_ image: NSImage, at point: CGPoint, mirrored: Bool) {
        let size = image.size
        let hotSpot = NSCursor.arrow.hotSpot
        let hotSpotX = mirrored ? size.width - hotSpot.x : hotSpot.x
        let rect = NSRect(
            x: point.x - hotSpotX,
            y: point.y - size.height + hotSpot.y,
            width: size.width,
            height: size.height
        )

        guard mirrored else {
            image.draw(in: rect)
            return
        }

        guard let context = NSGraphicsContext.current else {
            image.draw(in: rect)
            return
        }

        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.maxX, yBy: rect.minY)
        transform.scaleX(by: -1, yBy: 1)
        transform.concat()
        image.draw(in: NSRect(origin: .zero, size: size))
        context.restoreGraphicsState()
    }

    private func tintedCursorImage(color: NSColor) -> NSImage {
        let image = NSImage(size: cursorImage.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: cursorImage.size)
        cursorImage.draw(in: rect)
        color.withAlphaComponent(0.85).setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }

    private func drawPulse(at point: CGPoint, color: NSColor, progress: Double) {
        let radius = 12 + (28 * progress)
        let alpha = 0.45 * (1 - progress)
        color.withAlphaComponent(alpha).setStroke()
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 3
        path.stroke()
    }
}
