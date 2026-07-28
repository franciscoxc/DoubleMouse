import AppKit

private let sensitivityOptions: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = PointerOverlayController()
    private let clickPerformer = ClickPerformer()
    private lazy var hidMonitor = HIDMouseMonitor(delegate: self)

    private var didShowAccessibilityWarning = false
    private var blueButtonIsDown = false
    private var blueDragStarted = false
    private var bluePressPosition = CGPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "DoubleMouse")

        overlay.show()
        hidMonitor.start()
        showAccessibilityWarningIfNeeded()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
        }
        hidMonitor.stop()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let devices = NSMenuItem(title: "Blue Pointer Mouse", action: nil, keyEquivalent: "")
        devices.submenu = deviceSubmenu()
        menu.addItem(devices)

        let assignBlue = NSMenuItem(title: "Set Blue Pointer From Next Movement", action: #selector(assignSecondaryFromNextMovement), keyEquivalent: "")
        assignBlue.target = self
        menu.addItem(assignBlue)

        if let assignmentPrompt = hidMonitor.assignmentPrompt {
            let prompt = NSMenuItem(title: assignmentPrompt, action: nil, keyEquivalent: "")
            prompt.isEnabled = false
            menu.addItem(prompt)
        }

        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Pointer Speed", action: nil, keyEquivalent: "")
        speed.submenu = speedSubmenu()
        menu.addItem(speed)

        let accelerationItem = NSMenuItem(title: "Pointer Acceleration", action: #selector(toggleAcceleration), keyEquivalent: "")
        accelerationItem.target = self
        accelerationItem.state = overlay.acceleration ? .on : .off
        menu.addItem(accelerationItem)

        menu.addItem(.separator())

        let secondary = hidMonitor.secondaryDeviceName ?? "not selected"
        let capture = hidMonitor.isSecondaryDeviceSeized ? "exclusive" : "shared"
        let summary = NSMenuItem(title: "Blue Pointer: \(secondary) [\(capture)]", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        if !AXIsProcessTrusted() {
            let permission = NSMenuItem(title: "Grant Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
            permission.target = self
            menu.addItem(permission)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DoubleMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func deviceSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard !hidMonitor.allDevices.isEmpty else {
            let empty = NSMenuItem(title: "Move a mouse to detect devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }

        for device in hidMonitor.allDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectSecondaryDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == hidMonitor.selectedSecondaryDeviceID ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func speedSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for value in sensitivityOptions {
            let item = NSMenuItem(title: String(format: "%g×", value), action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(overlay.sensitivity - value) < 0.001 ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectSecondaryDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt64 else {
            return
        }
        hidMonitor.setSecondaryDevice(id: id)
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else {
            return
        }
        overlay.sensitivity = value
        rebuildMenu()
    }

    @objc private func toggleAcceleration() {
        overlay.acceleration.toggle()
        rebuildMenu()
    }

    @objc private func assignSecondaryFromNextMovement() {
        hidMonitor.assignSecondaryDeviceFromNextMovement()
    }

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func showAccessibilityWarningIfNeeded() {
        guard !AXIsProcessTrusted(), !didShowAccessibilityWarning else {
            return
        }

        didShowAccessibilityWarning = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "DoubleMouse Needs Accessibility Permission"
        alert.informativeText = "DoubleMouse needs this permission to press controls and emit clicks from the blue pointer. While running with swift run, macOS grants this permission to Terminal; packaged as an app, it will request permission as DoubleMouse."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibilityPermission()
        }
    }

}

extension AppDelegate: HIDMouseMonitorDelegate {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint) {
        overlay.moveSecondaryBy(delta)

        guard blueButtonIsDown else {
            return
        }

        let point = overlay.secondaryPointerPosition
        if !blueDragStarted,
           hypot(point.x - bluePressPosition.x, point.y - bluePressPosition.y) >= 3 {
            blueDragStarted = true
            clickPerformer.beginDrag(at: bluePressPosition, returningTo: NSEvent.mouseLocation)
        }
        if blueDragStarted {
            clickPerformer.drag(to: point, returningTo: NSEvent.mouseLocation)
        }
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: CGPoint) {
        clickPerformer.scroll(at: overlay.secondaryPointerPosition, delta: delta)
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton button: MouseButton, isPressed: Bool) {
        guard button == .left else {
            // Right button: no drag, macOS has no second button state to spare anyway.
            if !isPressed {
                clickPerformer.performRightClick(at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
                overlay.pulseSecondary()
            }
            return
        }

        guard isPressed != blueButtonIsDown else {
            return
        }

        blueButtonIsDown = isPressed
        if isPressed {
            blueDragStarted = false
            bluePressPosition = overlay.secondaryPointerPosition
            return
        }

        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
        } else {
            clickPerformer.performClick(at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
        }
        blueDragStarted = false
        overlay.pulseSecondary()
    }

    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor) {
        rebuildMenu()
    }
}
