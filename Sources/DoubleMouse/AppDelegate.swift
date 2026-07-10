import AppKit

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
        statusItem.button?.title = "DoubleMouse"
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "DoubleMouse")
        statusItem.button?.imagePosition = .imageLeading

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

        menu.addItem(deviceSelectionMenu(title: "Blue Pointer Mouse", selectedID: hidMonitor.selectedSecondaryDeviceID, action: #selector(selectSecondaryDevice(_:))))

        let assignBlue = NSMenuItem(title: "Set Blue Pointer From Next Movement", action: #selector(assignSecondaryFromNextMovement), keyEquivalent: "")
        assignBlue.target = self
        menu.addItem(assignBlue)

        if let assignmentPrompt = hidMonitor.assignmentPrompt {
            let prompt = NSMenuItem(title: assignmentPrompt, action: nil, keyEquivalent: "")
            prompt.isEnabled = false
            menu.addItem(prompt)
        }

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

        let quit = NSMenuItem(title: "Quit DoubleMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func deviceSelectionMenu(title: String, selectedID: UInt64?, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if hidMonitor.allDevices.isEmpty {
            let empty = NSMenuItem(title: "Move a mouse to detect devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for device in hidMonitor.allDevices {
                let item = NSMenuItem(title: device.name, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = String(device.id)
                item.state = device.id == selectedID ? .on : .off
                submenu.addItem(item)
            }
        }

        parent.submenu = submenu
        return parent
    }

    @objc private func selectSecondaryDevice(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String, let id = UInt64(rawID) else {
            return
        }
        hidMonitor.setSecondaryDevice(id: id)
    }

    @objc private func assignSecondaryFromNextMovement() {
        hidMonitor.assignSecondaryDeviceFromNextMovement()
    }

    @objc private func requestAccessibilityPermission() {
        requestAccessibilityIfNeeded(prompt: true)
    }

    private func requestAccessibilityIfNeeded(prompt: Bool = false) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
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
            requestAccessibilityIfNeeded(prompt: true)
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

    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: Int32) {
        clickPerformer.scroll(at: overlay.secondaryPointerPosition, verticalDelta: delta)
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton isPressed: Bool) {
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
