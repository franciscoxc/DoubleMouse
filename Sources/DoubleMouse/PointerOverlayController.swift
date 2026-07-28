import AppKit

/// Raw HID counts are not screen pixels: a 1600 DPI mouse moves far more counts per
/// centimetre than the macOS cursor moves points, and macOS applies its own acceleration
/// curve that we never see. Both knobs are here so the blue pointer can be matched to the
/// hardware by feel.
///
/// ponytail: linear ramp to 2x at 40 counts per report. Swap for a lookup table if it
/// still drifts from the system cursor at the extremes.
func scaledDelta(_ delta: CGPoint, sensitivity: Double, acceleration: Bool) -> CGPoint {
    var gain = sensitivity
    if acceleration {
        gain *= 1 + min(hypot(delta.x, delta.y), 40) / 40
    }
    return CGPoint(x: delta.x * gain, y: delta.y * gain)
}

final class PointerOverlayController {
    private let window: NSWindow
    private let pointerView = PointerView(frame: .zero)

    var sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }

    var acceleration = UserDefaults.standard.object(forKey: "acceleration") as? Bool ?? true {
        didSet { UserDefaults.standard.set(acceleration, forKey: "acceleration") }
    }

    /// Screen coordinates. The view draws in its own space, so it gets the converted point.
    private(set) var secondaryPointerPosition = CGPoint(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 300)

    init() {
        window = NSWindow(
            contentRect: PointerOverlayController.screensFrame(),
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

        syncViewPosition()

        // Plugging in a display or changing resolution moves every screen origin. Without
        // this the overlay keeps the old frame and the pointer cannot reach the new screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
    }

    func show() {
        window.orderFrontRegardless()
    }

    func moveSecondaryBy(_ delta: CGPoint) {
        let scaled = scaledDelta(delta, sensitivity: sensitivity, acceleration: acceleration)
        secondaryPointerPosition = clampedPoint(
            CGPoint(x: secondaryPointerPosition.x + scaled.x, y: secondaryPointerPosition.y - scaled.y)
        )
        syncViewPosition()
    }

    func pulseSecondary() {
        pointerView.pulse()
    }

    private func screensChanged() {
        window.setFrame(PointerOverlayController.screensFrame(), display: true)
        secondaryPointerPosition = clampedPoint(secondaryPointerPosition)
        syncViewPosition()
    }

    private func syncViewPosition() {
        let origin = window.frame.origin
        pointerView.pointerPosition = CGPoint(
            x: secondaryPointerPosition.x - origin.x,
            y: secondaryPointerPosition.y - origin.y
        )
    }

    private static func screensFrame() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
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
    /// View coordinates, not screen coordinates.
    var pointerPosition: CGPoint = .zero {
        didSet {
            // Repainting the union of every screen on each HID report is the whole frame
            // budget on a large desktop. Only the arrow and its pulse ever change.
            setNeedsDisplay(dirtyRect(around: oldValue))
            setNeedsDisplay(dirtyRect(around: pointerPosition))
        }
    }

    private var pulseUntil: Date?
    private let blueCursorImage = tintedArrowImage(color: .systemBlue)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPointerImage()
        drawPulseIfNeeded()
    }

    func pulse() {
        pulseUntil = Date().addingTimeInterval(0.35)
        setNeedsDisplay(dirtyRect(around: pointerPosition))
    }

    private func dirtyRect(around point: CGPoint) -> NSRect {
        // Covers the arrow plus the widest pulse ring.
        NSRect(x: point.x - 48, y: point.y - 48, width: 96, height: 96)
    }

    private func drawPulseIfNeeded() {
        guard let pulseUntil, pulseUntil > Date() else {
            return
        }

        let progress = 1.0 - min(max(pulseUntil.timeIntervalSinceNow / 0.35, 0), 1)
        let radius = 12 + (28 * progress)
        NSColor.systemBlue.withAlphaComponent(0.45 * (1 - progress)).setStroke()
        let path = NSBezierPath(ovalIn: CGRect(
            x: pointerPosition.x - radius,
            y: pointerPosition.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        path.lineWidth = 3
        path.stroke()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else {
                return
            }
            self.setNeedsDisplay(self.dirtyRect(around: self.pointerPosition))
        }
    }

    /// Drawn mirrored so the blue arrow is distinguishable from the system cursor at a glance.
    private func drawPointerImage() {
        let size = blueCursorImage.size
        let hotSpot = NSCursor.arrow.hotSpot
        let rect = NSRect(
            x: pointerPosition.x - (size.width - hotSpot.x),
            y: pointerPosition.y - size.height + hotSpot.y,
            width: size.width,
            height: size.height
        )

        guard let context = NSGraphicsContext.current else {
            blueCursorImage.draw(in: rect)
            return
        }

        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.maxX, yBy: rect.minY)
        transform.scaleX(by: -1, yBy: 1)
        transform.concat()
        blueCursorImage.draw(in: NSRect(origin: .zero, size: size))
        context.restoreGraphicsState()
    }
}

private func tintedArrowImage(color: NSColor) -> NSImage {
    let arrow = NSCursor.arrow.image
    let image = NSImage(size: arrow.size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: arrow.size)
    arrow.draw(in: rect)
    color.withAlphaComponent(0.85).setFill()
    rect.fill(using: .sourceAtop)
    image.unlockFocus()
    return image
}
