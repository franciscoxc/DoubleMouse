import AppKit
import ApplicationServices

final class ClickPerformer {
    private let source = CGEventSource(stateID: .privateState)

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    func performClick(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        if performAccessibilityPress(at: point) {
            return
        }
        performSyntheticClick(at: point, returningTo: returnPoint)
    }

    func beginDrag(at point: CGPoint, returningTo returnPoint: CGPoint) {
        postMouseEvent(.leftMouseDown, at: point, returningTo: returnPoint)
    }

    func drag(to point: CGPoint, returningTo returnPoint: CGPoint) {
        postMouseEvent(.leftMouseDragged, at: point, returningTo: returnPoint)
    }

    func endDrag(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        postMouseEvent(.leftMouseUp, at: point, returningTo: returnPoint)
    }

    func scroll(at point: CGPoint, verticalDelta: Int32) {
        let returnPoint = NSEvent.mouseLocation
        guard verticalDelta != 0,
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .line,
                wheelCount: 1,
                wheel1: verticalDelta,
                wheel2: 0,
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
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(quartzPoint.x), Float(quartzPoint.y), &element)
        guard error == .success, let element else {
            return false
        }

        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func performSyntheticClick(at point: CGPoint, returningTo returnPoint: CGPoint?) {
        postMouseEvent(.leftMouseDown, at: point)
        postMouseEvent(.leftMouseUp, at: point)

        if let returnPoint {
            moveSystemCursor(to: returnPoint)
        }
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: quartzPoint(fromAppKitPoint: point),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)

        if let returnPoint {
            moveSystemCursor(to: returnPoint)
        }
    }

    private func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
           let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let displayBounds = CGDisplayBounds(displayID)
            let localX = point.x - screen.frame.minX
            let localYFromBottom = point.y - screen.frame.minY
            return CGPoint(
                x: displayBounds.minX + localX,
                y: displayBounds.maxY - localYFromBottom
            )
        }

        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: point.x, y: mainBounds.maxY - point.y)
    }
}
