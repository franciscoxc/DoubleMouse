import AppKit
import ApplicationServices

/// Roles where an Accessibility press is equivalent to a real click. Anything else — text
/// fields, tables, web areas, canvases — needs a real event, because AXPress does not place
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

final class ClickPerformer {
    private let source = CGEventSource(stateID: .privateState)

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    /// macOS keeps one global mouse-button state, so a blue click has to be emitted at the
    /// blue pointer and the system cursor put back where the user left it. The Accessibility
    /// path avoids that round trip entirely when the target is a plain control.
    func performClick(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        if performAccessibilityPress(at: point) {
            return
        }
        postMouseEvent(.leftMouseDown, button: .left, at: point)
        postMouseEvent(.leftMouseUp, button: .left, at: point, returningTo: returnPoint)
    }

    func performRightClick(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        // No Accessibility equivalent: AXPress cannot raise a context menu.
        postMouseEvent(.rightMouseDown, button: .right, at: point)
        postMouseEvent(.rightMouseUp, button: .right, at: point, returningTo: returnPoint)
    }

    func beginDrag(at point: CGPoint, returningTo returnPoint: CGPoint) {
        postMouseEvent(.leftMouseDown, button: .left, at: point, returningTo: returnPoint)
    }

    func drag(to point: CGPoint, returningTo returnPoint: CGPoint) {
        postMouseEvent(.leftMouseDragged, button: .left, at: point, returningTo: returnPoint)
    }

    func endDrag(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        postMouseEvent(.leftMouseUp, button: .left, at: point, returningTo: returnPoint)
    }

    func scroll(at point: CGPoint, delta: CGPoint) {
        let returnPoint = NSEvent.mouseLocation
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
        event.post(tap: .cghidEventTap)
        moveSystemCursor(to: returnPoint)
    }

    func moveSystemCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(quartzPoint(fromAppKitPoint: point))
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
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

    private func postMouseEvent(_ type: CGEventType, button: CGMouseButton, at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: quartzPoint(fromAppKitPoint: point),
            mouseButton: button
        )?.post(tap: .cghidEventTap)

        if let returnPoint {
            moveSystemCursor(to: returnPoint)
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
