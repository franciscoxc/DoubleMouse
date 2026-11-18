import AppKit
import ApplicationServices

/// Roles where an Accessibility press is equivalent to a real click. Anything else (text
/// fields, tables, web areas, canvases) needs a real event, because AXPress does not place
/// a caret, select a row, or start a selection.
private let pressableRoles: Set<String> = [
    "AXButton",
    "AXCheckBox",
    "AXRadioButton",
    "AXPopUpButton",
    "AXMenuButton",
    "AXMenuItem",
    "AXDisclosureTriangle"
]

/// The count a press gets, numbered the way the HID system numbers real clicks: one more than
/// the press before if it came within the double-click interval and on about the same spot.
func nextClickCount(after previous: (point: CGPoint, time: TimeInterval, count: Int64)?, at point: CGPoint, time: TimeInterval, interval: TimeInterval) -> Int64 {
    guard let previous,
          time - previous.time <= interval,
          hypot(point.x - previous.point.x, point.y - previous.point.y) <= 5 else {
        return 1
    }
    return previous.count + 1
}

final class ClickPerformer {
    private let source = CGEventSource(stateID: .privateState)

    // AppKit reads double and triple clicks from the count on the event, not from timing, and a
    // posted event carries whatever count it was given: without this, a double-click from the
    // blue pointer arrived as two single clicks and opened nothing.
    private var lastPress: (button: CGMouseButton, point: CGPoint, time: TimeInterval, count: Int64)?
    private var dragCount: Int64 = 1

    // Where the system cursor belongs, where our last event sent it, and a late check that it
    // came back. See cursorHome().
    private var home = CGPoint.zero
    private var lastPosted: (point: CGPoint, time: TimeInterval)?
    private var settle: DispatchWorkItem?

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    /// macOS keeps one global mouse-button state, so a blue click has to be emitted at the
    /// blue pointer and the system cursor put back where the user left it. The Accessibility
    /// path avoids that round trip entirely when the target is a plain control.
    func performClick(_ button: CGMouseButton, at point: CGPoint) {
        let count = pressCount(button, at: point)
        // Not with a modifier held: AXPress has nowhere to carry it, so a Command-click went
        // through as a plain press.
        if button == .left, modifierFlags.isEmpty, performAccessibilityPress(at: point) {
            return
        }
        let types = eventTypes(for: button)
        let home = cursorHome()
        postMouseEvent(types.down, button: button, at: point, count: count)
        postMouseEvent(types.up, button: button, at: point, count: count, returningTo: home)
    }

    func beginDrag(at point: CGPoint) {
        dragCount = pressCount(.left, at: point)
        postMouseEvent(.leftMouseDown, button: .left, at: point, count: dragCount, returningTo: cursorHome())
    }

    func drag(to point: CGPoint) {
        postMouseEvent(.leftMouseDragged, button: .left, at: point, count: dragCount, returningTo: cursorHome())
    }

    func endDrag(at point: CGPoint) {
        postMouseEvent(.leftMouseUp, button: .left, at: point, count: dragCount, returningTo: cursorHome())
    }

    func scroll(at point: CGPoint, delta: CGPoint) {
        let home = cursorHome()
        guard delta != .zero,
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .line,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(delta.y)),
                wheel2: Int32(clamping: Int(delta.x)),
                wheel3: 0
              ) else {
            return
        }

        event.location = quartzPoint(fromAppKitPoint: point)
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
        sendCursorHome(to: home, afterEventAt: point)
    }

    func moveSystemCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(quartzPoint(fromAppKitPoint: point))
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    /// Where the system cursor belongs: where its own mouse left it.
    // ponytail-keep: not simply the current position. Reading it back before every event, a blue
    // drag or scroll took the system arrow to the blue pointer and left it there: every blue
    // event puts the cursor on the blue pointer for a moment, a drag or a scroll is a stream of
    // them, and read between two, a cursor still sitting there became the place to return to. A
    // position that is exactly where our last event just put it is our doing, not the person's.
    // With this, on a Mac mini with a Logitech mouse and a Magic Trackpad (2026-11-18), the arrow
    // stays in its place; what is left is a brief flicker as it goes and comes back.
    private func cursorHome() -> CGPoint {
        let now = NSEvent.mouseLocation
        if let lastPosted, ProcessInfo.processInfo.systemUptime - lastPosted.time < 0.3,
           hypot(now.x - lastPosted.point.x, now.y - lastPosted.point.y) < 2 {
            return home
        }
        home = now
        return now
    }

    /// Puts the cursor back after an event, and looks again a moment after the last one.
    // The second look is for an event that lands after its own warp: the two reach the window
    // server by different roads, and if the warp wins nothing else brings the cursor back.
    private func sendCursorHome(to home: CGPoint, afterEventAt point: CGPoint) {
        lastPosted = (point, ProcessInfo.processInfo.systemUptime)
        moveSystemCursor(to: home)

        settle?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, let lastPosted = self.lastPosted else {
                return
            }
            let now = NSEvent.mouseLocation
            if hypot(now.x - lastPosted.point.x, now.y - lastPosted.point.y) < 2 {
                self.moveSystemCursor(to: self.home)
            }
        }
        settle = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
    }

    // The keyboard's modifiers at this moment. A private event source keeps no keyboard state
    // of its own, so without them a Shift-click from the blue pointer arrived as a plain click.
    private var modifierFlags: CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    private func pressCount(_ button: CGMouseButton, at point: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastPress.flatMap { $0.button == button ? ($0.point, $0.time, $0.count) : nil }
        let count = nextClickCount(after: previous, at: point, time: now, interval: NSEvent.doubleClickInterval)
        lastPress = (button, point, now, count)
        return count
    }

    private func eventTypes(for button: CGMouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left:
            return (.leftMouseDown, .leftMouseUp)
        case .right:
            return (.rightMouseDown, .rightMouseUp)
        default:
            return (.otherMouseDown, .otherMouseUp)
        }
    }

    private func performAccessibilityPress(at point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        let quartzPoint = quartzPoint(fromAppKitPoint: point)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(quartzPoint.x), Float(quartzPoint.y), &element) == .success,
              let element else {
            return false
        }

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String,
              pressableRoles.contains(role) else {
            return false
        }

        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func postMouseEvent(_ type: CGEventType, button: CGMouseButton, at point: CGPoint, count: Int64, returningTo returnPoint: CGPoint? = nil) {
        if let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: quartzPoint(fromAppKitPoint: point),
            mouseButton: button
        ) {
            event.setIntegerValueField(.mouseEventClickState, value: count)
            event.flags = modifierFlags
            event.post(tap: .cghidEventTap)
        }

        if let returnPoint {
            sendCursorHome(to: returnPoint, afterEventAt: point)
        }
    }

    private func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
           let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            return CGPoint(
                x: displayBounds.minX + (point.x - screen.frame.minX),
                y: displayBounds.maxY - (point.y - screen.frame.minY)
            )
        }

        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: point.x, y: mainBounds.maxY - point.y)
    }
}
