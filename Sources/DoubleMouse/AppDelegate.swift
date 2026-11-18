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
        releaseBlueButton()
        hidMonitor.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Input Monitoring may have been granted since the last try.
        hidMonitor.captureSecondaryDevice()
        menu.removeAllItems()

        let state = hidMonitor.secondaryDeviceName ?? (hidMonitor.hasSavedChoice ? "mouse not connected" : "not chosen yet")
        let devices = NSMenuItem(title: "Blue Pointer: \(state)", action: nil, keyEquivalent: "")
        devices.submenu = deviceSubmenu()
        menu.addItem(devices)

        if hidMonitor.allDevices.count < 2 {
            menu.addItem(note("Connect a second mouse or trackpad to use it"))
        } else if hidMonitor.isPaused {
            menu.addItem(action("Resume Blue Pointer", #selector(togglePause)))
        } else if hidMonitor.secondaryDeviceName != nil && !hidMonitor.isSecondaryDeviceSeized {
            menu.addItem(note("macOS won't hand this mouse over to DoubleMouse"))
            menu.addItem(action("Open Input Monitoring Settings…", #selector(openInputMonitoring)))
        } else if hidMonitor.isSecondaryDeviceSeized {
            menu.addItem(action("Pause Blue Pointer", #selector(togglePause)))
        }

        let speed = NSMenuItem(title: "Pointer Speed", action: nil, keyEquivalent: "")
        speed.submenu = speedSubmenu()
        menu.addItem(speed)

        menu.addItem(.separator())

        let openAtLogin = action("Open at Login", #selector(toggleOpenAtLogin))
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(openAtLogin)

        if !AXIsProcessTrusted() {
            menu.addItem(action("Grant Accessibility Permission…", #selector(showAccessibilityAlert)))
        }

        let updates = action("Check for Updates…", #selector(checkForUpdates))
        if #available(macOS 14.4, *) {
            updates.subtitle = Updater.current == "0" ? "Development build" : "Version \(Updater.current)"
        }
        menu.addItem(updates)

        menu.addItem(.separator())
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
        submenu.addItem(.separator())
        submenu.addItem(action("Choose by Clicking…", #selector(chooseBlueMouse)))
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
        submenu.addItem(.separator())
        let acceleration = action("Acceleration", #selector(toggleAcceleration))
        acceleration.state = overlay.acceleration ? .on : .off
        submenu.addItem(acceleration)
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
        alert.informativeText = "Click \"Use This Mouse\" with the mouse that should move the blue pointer. The other mouse or trackpad keeps the regular pointer."
        alert.addButton(withTitle: "Use This Mouse")
        alert.addButton(withTitle: "Cancel")
        // Only a click says which mouse it was. Return would pick whichever one moved last.
        alert.buttons[0].keyEquivalent = ""
        let shownAt = ProcessInfo.processInfo.systemUptime
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        guard let id = hidMonitor.deviceUsed(since: shownAt) else {
            // No HID report arrived during the dialog. Either the click came from a trackpad that
            // only reports touches (the original Magic Trackpad sent none), or macOS is withholding them.
            let unseen = NSAlert()
            unseen.messageText = "DoubleMouse Didn't See a Mouse Click"
            unseen.informativeText = "Some trackpads, like the original Magic Trackpad, only report touches and can't move the blue pointer. If you clicked with one, choose again and click with a mouse. If you did click with a mouse, turn on DoubleMouse in System Settings, under Privacy & Security > Input Monitoring."
            unseen.addButton(withTitle: "OK")
            unseen.addButton(withTitle: "Open Input Monitoring Settings")
            if unseen.runModal() == .alertSecondButtonReturn {
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

    /// Pausing hands the blue mouse back to macOS, so it moves the regular pointer like any mouse,
    /// hover included: the one thing the blue pointer cannot have.
    @objc private func togglePause() {
        if hidMonitor.isPaused {
            overlay.moveSecondary(to: NSEvent.mouseLocation)
            hidMonitor.isPaused = false
            overlay.show()
            overlay.pulseSecondary()
        } else {
            releaseBlueButton()
            // The regular pointer picks up where the blue one was, so the hand on the blue mouse
            // keeps pointing at the same thing.
            clickPerformer.moveSystemCursor(to: overlay.secondaryPointerPosition)
            hidMonitor.isPaused = true
            overlay.hide()
        }
        statusItem.button?.appearsDisabled = hidMonitor.isPaused
    }

    /// Lets go of a blue button that is still down, before the blue mouse changes hands.
    private func releaseBlueButton() {
        holdTimer?.cancel()
        holdTimer = nil
        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition)
        }
        blueButtonIsDown = false
        blueDragStarted = false
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
        showAccessibilityAlert()
    }

    @objc private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "DoubleMouse Needs Accessibility Permission"
        // ponytail-keep: the second half is the case that bit. macOS keeps an entry tied to the
        // signature of the build that created it, and turning its switch on again does not move it
        // to the new one: after updating from the ad-hoc 1.2.1, the switch showed on while TCC
        // still checked 1.2.1's cdhash, and every blue click was dropped. Removing the entry is
        // what clears it.
        alert.informativeText = "It is what lets the blue pointer click, scroll, and drag. Turn on DoubleMouse in System Settings, under Privacy & Security > Accessibility.\n\nIf DoubleMouse is already there and turned on, the entry belongs to an older version: select it, remove it with the minus button, and open DoubleMouse again."
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
        clickPerformer.beginDrag(at: bluePressPosition)
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
            clickPerformer.drag(to: point)
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
                clickPerformer.performClick(button, at: overlay.secondaryPointerPosition)
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
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition)
        } else {
            clickPerformer.performClick(.left, at: overlay.secondaryPointerPosition)
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
