import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = PointerOverlayController()
    private let clickPerformer = ClickPerformer()
    private lazy var hidMonitor = HIDMouseMonitor(delegate: self)

    private var didShowAccessibilityWarning = false
    private var invertBluePointerYAxis = true
    private var frozenSystemCursorPositionDuringBlueMove: CGPoint?
    private var releaseWorkItem: DispatchWorkItem?
    private let clickSuppressor = PhysicalClickSuppressor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "DoubleMouse"
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "DoubleMouse")
        statusItem.button?.imagePosition = .imageLeading

        overlay.show()
        overlay.invertYAxis = invertBluePointerYAxis
        hidMonitor.start()
        clickSuppressor.start()
        showAccessibilityWarningIfNeeded()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseWorkItem?.cancel()
        clickSuppressor.stop()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "DoubleMouse", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(deviceSelectionMenu(title: "Mouse del sistema", selectedID: hidMonitor.selectedPrimaryDeviceID, action: #selector(selectPrimaryDevice(_:))))
        menu.addItem(deviceSelectionMenu(title: "Mouse flecha azul", selectedID: hidMonitor.selectedSecondaryDeviceID, action: #selector(selectSecondaryDevice(_:))))

        let assignSystem = NSMenuItem(title: "Elegir mouse del sistema con el proximo movimiento", action: #selector(assignPrimaryFromNextMovement), keyEquivalent: "")
        assignSystem.target = self
        menu.addItem(assignSystem)

        let assignBlue = NSMenuItem(title: "Elegir flecha azul con el proximo movimiento", action: #selector(assignSecondaryFromNextMovement), keyEquivalent: "")
        assignBlue.target = self
        menu.addItem(assignBlue)

        if let assignmentPrompt = hidMonitor.assignmentPrompt {
            let prompt = NSMenuItem(title: assignmentPrompt, action: nil, keyEquivalent: "")
            prompt.isEnabled = false
            menu.addItem(prompt)
        }

        let invertY = NSMenuItem(title: "Invertir eje Y de la flecha azul", action: #selector(toggleInvertBluePointerYAxis), keyEquivalent: "")
        invertY.target = self
        invertY.state = invertBluePointerYAxis ? .on : .off
        menu.addItem(invertY)

        menu.addItem(.separator())

        let primary = hidMonitor.primaryDeviceName ?? "sin elegir"
        let secondary = hidMonitor.secondaryDeviceName ?? "sin elegir"
        let summary = NSMenuItem(title: "Usando: \(primary) / \(secondary)", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        let permission = NSMenuItem(title: "Pedir permiso de accesibilidad", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Salir de DoubleMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func deviceSelectionMenu(title: String, selectedID: UInt64?, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if hidMonitor.allDevices.isEmpty {
            let empty = NSMenuItem(title: "Mueve un mouse para detectar dispositivos", action: nil, keyEquivalent: "")
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

    @objc private func selectPrimaryDevice(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String, let id = UInt64(rawID) else {
            return
        }
        hidMonitor.setPrimaryDevice(id: id)
        resetMovementCancellation()
    }

    @objc private func selectSecondaryDevice(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String, let id = UInt64(rawID) else {
            return
        }
        hidMonitor.setSecondaryDevice(id: id)
        resetMovementCancellation()
    }

    @objc private func assignPrimaryFromNextMovement() {
        hidMonitor.assignDeviceFromNextMovement(.primary)
    }

    @objc private func assignSecondaryFromNextMovement() {
        hidMonitor.assignDeviceFromNextMovement(.secondary)
    }

    @objc private func toggleInvertBluePointerYAxis() {
        invertBluePointerYAxis.toggle()
        overlay.invertYAxis = invertBluePointerYAxis
        rebuildMenu()
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
        alert.messageText = "DoubleMouse necesita permiso de accesibilidad"
        alert.informativeText = "DoubleMouse necesita este permiso para presionar controles y emitir clics desde la flecha azul. Mientras se ejecuta con swift run, macOS le da el permiso a Terminal; empaquetada como app lo pedira como DoubleMouse."
        alert.addButton(withTitle: "Abrir ajustes")
        alert.addButton(withTitle: "Despues")

        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibilityIfNeeded(prompt: true)
        }
    }

    private func resetMovementCancellation() {
        frozenSystemCursorPositionDuringBlueMove = nil
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
    }

    private func primeMovementCancellation() {
        resetMovementCancellation()
    }

}

extension AppDelegate: HIDMouseMonitorDelegate {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMovePrimaryBy delta: CGPoint) {
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint) {
        overlay.moveBy(delta)
        cancelObservedSystemMovementFromBlueMouse()
    }

    private func cancelObservedSystemMovementFromBlueMouse() {
        let frozenPosition = frozenSystemCursorPositionDuringBlueMove ?? NSEvent.mouseLocation
        frozenSystemCursorPositionDuringBlueMove = frozenPosition
        clickPerformer.moveSystemCursor(to: frozenPosition)
        scheduleMovementRelease()
    }

    private func scheduleMovementRelease() {
        releaseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.frozenSystemCursorPositionDuringBlueMove = nil
            self.releaseWorkItem = nil
        }

        releaseWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func mouseMonitorDidSecondaryClick(_ monitor: HIDMouseMonitor, clickCount: Int) {
        let returnPosition = frozenSystemCursorPositionDuringBlueMove ?? NSEvent.mouseLocation
        clickSuppressor.suppressNextLeftClick()
        let clickPoint = overlay.pointerPosition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.clickPerformer.performClick(at: clickPoint, returningTo: returnPosition)
        }
        overlay.pulse()
    }

    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor) {
        primeMovementCancellation()
        rebuildMenu()
    }
}
