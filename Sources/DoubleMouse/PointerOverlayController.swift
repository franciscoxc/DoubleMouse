import AppKit

final class PointerOverlayController {
    private let window: NSWindow
    private let pointerView: PointerView

    var pointerPosition: CGPoint = CGPoint(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 300) {
        didSet {
            pointerView.pointerPosition = pointerPosition
        }
    }

    var invertYAxis = false

    init() {
        let frame = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }

        pointerView = PointerView(frame: frame)
        pointerView.pointerPosition = pointerPosition

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

    func moveBy(_ delta: CGPoint) {
        let frame = window.frame
        let yDelta = invertYAxis ? -delta.y : delta.y
        var next = CGPoint(x: pointerPosition.x + delta.x, y: pointerPosition.y + yDelta)
        next.x = min(max(next.x, frame.minX), frame.maxX)
        next.y = min(max(next.y, frame.minY), frame.maxY)
        pointerPosition = next
    }

    func pulse() {
        pointerView.pulse()
    }
}

final class PointerView: NSView {
    var pointerPosition: CGPoint = .zero {
        didSet { needsDisplay = true }
    }

    private var pulseUntil: Date?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawPointer(at: pointerPosition, color: .systemBlue)

        if let pulseUntil, pulseUntil > Date() {
            let remaining = pulseUntil.timeIntervalSinceNow
            let progress = 1.0 - min(max(remaining / 0.35, 0), 1)
            drawPulse(at: pointerPosition, color: .systemBlue, progress: progress)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                self?.needsDisplay = true
            }
        }
    }

    func pulse() {
        pulseUntil = Date().addingTimeInterval(0.35)
        needsDisplay = true
    }

    private func drawPointer(at point: CGPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: point)
        path.line(to: CGPoint(x: point.x - 7, y: point.y - 36))
        path.line(to: CGPoint(x: point.x - 15, y: point.y - 25))
        path.line(to: CGPoint(x: point.x - 22, y: point.y - 43))
        path.line(to: CGPoint(x: point.x - 31, y: point.y - 39))
        path.line(to: CGPoint(x: point.x - 24, y: point.y - 22))
        path.line(to: CGPoint(x: point.x - 38, y: point.y - 23))
        path.close()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.lineJoinStyle = .round
        path.lineWidth = 6
        path.stroke()

        color.setFill()
        path.fill()
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
