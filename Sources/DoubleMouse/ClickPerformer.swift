import AppKit
import ApplicationServices

final class ClickPerformer {
    func performClick(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        if performAccessibilityPress(at: point) {
            if let returnPoint {
                moveSystemCursor(to: returnPoint)
            }
            return
        }
        performSyntheticClick(at: point, returningTo: returnPoint)
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
        let source = CGEventSource(stateID: .privateState)
        source?.userData = EventMarker.doubleMouseSyntheticClick

        let quartzPoint = quartzPoint(fromAppKitPoint: point)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: quartzPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: quartzPoint, mouseButton: .left) else {
            return
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

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
