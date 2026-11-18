import AppKit
import ServiceManagement

private let sensitivityOptions: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]

/// How long the blue left button has to stay down, without moving, before it becomes a real
/// press instead of a click on release. Long enough that an ordinary click still goes the quick
/// way, through Accessibility, with no trip of the system cursor.
private let holdDelay: TimeInterval = 0.35

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = PointerOverlayController()
    private let clickPerformer = ClickPerformer()
    private lazy var hidMonitor = HIDMouseMonitor(delegate: self)

    private var didShowAccessibilityWarning = false
    private var didOfferChoice = false
    private var blueButtonIsDown = false
    private var blueDragStarted = false
    private var bluePressPosition = CGPoint.zero
    private var holdTimer: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "DoubleMouse")
        let menu = NSMenu()
        // Rebuilt each time it opens, so a permission granted in System Settings shows without a relaunch.
        menu.delegate = self
        statusItem.menu = menu

        overlay.show()
        hidMonitor.start()
        showAccessibilityWarningIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
        }
        hidMonitor.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Input Monitoring may have been granted since the last try.
        hidMonitor.captureSecondaryDevice()
        menu.removeAllItems()

        if let name = hidMonitor.secondaryDeviceName {
            menu.addItem(note("Blue Pointer: \(name)"))
        } else {
            menu.addItem(note(hidMonitor.hasSavedChoice ? "Blue Pointer: mouse not connected" : "Blue Pointer: not chosen yet"))
        }
        if hidMonitor.allDevices.count < 2 {
            menu.addItem(note("Connect a second mouse or trackpad to use it"))
        } else if hidMonitor.secondaryDeviceName != nil && !hidMonitor.isSecondaryDeviceSeized {
            menu.addItem(note("macOS won't hand this mouse over to DoubleMouse"))
            menu.addItem(action("Open Input Monitoring Settings…", #selector(openInputMonitoring)))
        }

        let devices = NSMenuItem(title: "Blue Pointer Mouse", action: nil, keyEquivalent: "")
        devices.submenu = deviceSubmenu()
        menu.addItem(devices)
        menu.addItem(action("Choose Blue Pointer Mouse…", #selector(chooseBlueMouse)))

        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Pointer Speed", action: nil, keyEquivalent: "")
        speed.submenu = speedSubmenu()
        menu.addItem(speed)

        let acceleration = action("Pointer Acceleration", #selector(toggleAcceleration))
        acceleration.state = overlay.acceleration ? .on : .off
        menu.addItem(acceleration)

        menu.addItem(.separator())

        let openAtLogin = action("Open at Login", #selector(toggleOpenAtLogin))
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(openAtLogin)

        if !AXIsProcessTrusted() {
            menu.addItem(action("Grant Accessibility Permission…", #selector(requestAccessibilityPermission)))
        }

        menu.addItem(.separator())
        menu.addItem(note(Updater.current == "0" ? "DoubleMouse (development build)" : "DoubleMouse \(Updater.current)"))
        menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(NSMenuItem(title: "Quit DoubleMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func deviceSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard !hidMonitor.allDevices.isEmpty else {
            submenu.addItem(note("Move a mouse to detect devices"))
            return submenu
        }

        for device in hidMonitor.allDevices {
            let item = action(device.name, #selector(selectSecondaryDevice(_:)))
            item.representedObject = device.id
            item.state = device.id == hidMonitor.selectedSecondaryDeviceID ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func speedSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for value in sensitivityOptions {
            let item = action(String(format: "%g×", value), #selector(selectSensitivity(_:)))
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
    }

    @objc private func toggleAcceleration() {
        overlay.acceleration.toggle()
    }

    /// The blue mouse is the one that clicks the button. Waiting for "the next movement" caught the
    /// main mouse whenever the hand on it moved first.
    @objc private func chooseBlueMouse() {
        NSApp.activate(ignoringOtherApps: true)
        guard hidMonitor.allDevices.count >= 2 else {
            let alert = NSAlert()
            alert.messageText = "Connect a Second Mouse"
            alert.informativeText = "DoubleMouse needs two pointing devices: two mice, or the trackpad and a mouse. Connect the second one, then choose it here."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Choose the Blue Pointer Mouse"
        alert.informativeText = "Click \"Use This Mouse\" with the mouse or trackpad that should move the blue pointer. The other one keeps the regular pointer."
        alert.addButton(withTitle: "Use This Mouse")
        alert.addButton(withTitle: "Cancel")
        // Only a click says which mouse it was. Return would pick whichever one moved last.
        alert.buttons[0].keyEquivalent = ""
        let shownAt = ProcessInfo.processInfo.systemUptime
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        guard let id = hidMonitor.deviceUsed(since: shownAt) else {
            // Not one HID report arrived during the whole dialog: macOS is withholding them.
            let blocked = NSAlert()
            blocked.messageText = "DoubleMouse Can't See Your Mice"
            blocked.informativeText = "Turn on DoubleMouse in System Settings, under Privacy & Security > Input Monitoring, then choose the blue pointer mouse again."
            blocked.addButton(withTitle: "Open System Settings")
            blocked.addButton(withTitle: "Later")
            if blocked.runModal() == .alertFirstButtonReturn {
                HIDMouseMonitor.requestInputMonitoring()
            }
            return
        }
        hidMonitor.setSecondaryDevice(id: id)
        overlay.pulseSecondary()
    }

    @objc private func openInputMonitoring() {
        HIDMouseMonitor.requestInputMonitoring()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
            return
        }
        // macOS can hold a new login item until it is approved in System Settings.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func checkForUpdates() {
        Task { await Updater.check() }
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
        alert.informativeText = "It is what lets the blue pointer click, scroll, and drag. Turn on DoubleMouse in System Settings, under Privacy & Security > Accessibility."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibilityPermission()
        }
    }

    /// The first time two pointing devices are connected, ask which one is blue instead of guessing.
    private func offerChoiceIfNeeded() {
        guard !didOfferChoice, !hidMonitor.hasSavedChoice, hidMonitor.allDevices.count >= 2 else {
            return
        }
        didOfferChoice = true
        chooseBlueMouse()
    }

    private func startBluePress() {
        guard blueButtonIsDown, !blueDragStarted else {
            return
        }
        blueDragStarted = true
        clickPerformer.beginDrag(at: bluePressPosition, returningTo: NSEvent.mouseLocation)
    }
}

extension AppDelegate: HIDMouseMonitorDelegate {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint) {
        overlay.moveSecondaryBy(delta)

        guard blueButtonIsDown else {
            return
        }

        let point = overlay.secondaryPointerPosition
        if hypot(point.x - bluePressPosition.x, point.y - bluePressPosition.y) >= 3 {
            startBluePress()
        }
        if blueDragStarted {
            clickPerformer.drag(to: point, returningTo: NSEvent.mouseLocation)
        }
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: CGPoint) {
        clickPerformer.scroll(at: overlay.secondaryPointerPosition, delta: delta)
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton button: CGMouseButton, isPressed: Bool) {
        guard button == .left else {
            // Right, middle, and side buttons click on release. Only the left one holds and drags:
            // macOS has a single button state, and the left button already keeps it busy.
            if !isPressed {
                clickPerformer.performClick(button, at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
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
            // A press held still is a press, not a click waiting for its release: buttons that
            // repeat, menus that open on hold, and anything that shows it is being pressed.
            let hold = DispatchWorkItem { [weak self] in
                self?.startBluePress()
            }
            holdTimer = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: hold)
            return
        }

        holdTimer?.cancel()
        holdTimer = nil
        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
        } else {
            clickPerformer.performClick(.left, at: overlay.secondaryPointerPosition, returningTo: NSEvent.mouseLocation)
        }
        blueDragStarted = false
        overlay.pulseSecondary()
    }

    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor) {
        // In the default mode only, so the question never lands on top of the Accessibility alert
        // or runs from inside a HID callback: it waits until no alert or menu is open.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            self?.offerChoiceIfNeeded()
        }
    }
}
