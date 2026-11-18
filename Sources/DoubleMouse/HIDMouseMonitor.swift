import AppKit
import IOKit.hid

protocol HIDMouseMonitorDelegate: AnyObject {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: CGPoint)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton button: CGMouseButton, isPressed: Bool)
    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor)
}

private let secondaryDeviceDefaultsKey = "secondaryDeviceKey"

// Common modes, not the default one: the menu and every alert run the main run loop in a mode of
// their own, and scheduled in the default mode alone the blue pointer froze while one was open.
private let runLoopMode = CFRunLoopMode.commonModes.rawValue

final class HIDMouseMonitor {
    weak var delegate: HIDMouseMonitorDelegate?

    private var manager: IOHIDManager!
    private var devices: [UInt64: HIDMouseDevice] = [:]
    private var secondaryDeviceID: UInt64?
    private var seizedSecondaryDeviceID: UInt64?

    // The last device to click and the last to move, any device, so the person can pick the blue
    // one by using it.
    private var lastPress: (device: UInt64, time: TimeInterval)?
    private var lastMove: (device: UInt64, time: TimeInterval)?

    // HID reports arrive one element at a time (X, then Y, then buttons). Accumulate a
    // whole report before telling the delegate, so movement is one diagonal step and one
    // redraw instead of two axis-aligned ones.
    private var pendingDelta = CGPoint.zero
    private var flushScheduled = false

    var secondaryDeviceName: String? {
        guard let secondaryDeviceID else {
            return nil
        }
        return devices[secondaryDeviceID]?.name
    }

    var allDevices: [HIDMouseDevice] {
        devices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedSecondaryDeviceID: UInt64? {
        secondaryDeviceID
    }

    var isSecondaryDeviceSeized: Bool {
        seizedSecondaryDeviceID == secondaryDeviceID && secondaryDeviceID != nil
    }

    /// Whether a blue mouse was ever chosen, even one that is not plugged in right now.
    var hasSavedChoice: Bool {
        UserDefaults.standard.string(forKey: secondaryDeviceDefaultsKey) != nil
    }

    init(delegate: HIDMouseMonitorDelegate?) {
        self.delegate = delegate
    }

    func start() {
        // Public SDK value for kIOHIDManagerOptionIndependentDevices.
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0x8))

        let matching = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer,
                kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad
            ]
        ] as CFArray

        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), runLoopMode)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        for device in devices.values {
            IOHIDDeviceUnscheduleFromRunLoop(device.reference, CFRunLoopGetMain(), runLoopMode)
            IOHIDDeviceClose(device.reference, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedSecondaryDeviceID = nil
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), runLoopMode)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setSecondaryDevice(id: UInt64) {
        guard let device = devices[id] else {
            return
        }

        secondaryDeviceID = id
        UserDefaults.standard.set(device.persistentKey, forKey: secondaryDeviceDefaultsKey)
        captureSecondaryDevice()
        delegate?.mouseMonitorDevicesChanged(self)
    }

    /// The device the person used since `start`: the one that clicked or, failing that, the one
    /// that moved. A trackpad tap may never reach HID as a button press, but the movement that
    /// brought the pointer there does.
    func deviceUsed(since start: TimeInterval) -> UInt64? {
        if let lastPress, lastPress.time >= start, devices[lastPress.device] != nil {
            return lastPress.device
        }
        if let lastMove, lastMove.time >= start, devices[lastMove.device] != nil {
            return lastMove.device
        }
        return nil
    }

    /// Takes the chosen device away from macOS, so it moves only the blue pointer, or hands it
    /// back. Safe to call again: a device that could not be seized before is tried once more.
    func captureSecondaryDevice() {
        // Never the last pointing device: with nothing left to move the regular pointer, the
        // person could not even reach the menu to undo it.
        let wanted = devices.count >= 2 ? secondaryDeviceID : nil
        guard seizedSecondaryDeviceID != wanted else {
            return
        }

        if let seizedSecondaryDeviceID, let oldDevice = devices[seizedSecondaryDeviceID]?.reference {
            IOHIDDeviceClose(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDDeviceOpen(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedSecondaryDeviceID = nil

        guard let wanted, let device = devices[wanted]?.reference else {
            return
        }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess {
            seizedSecondaryDeviceID = wanted
        } else {
            IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// Input Monitoring: the system prompt the first time, System Settings after that, because
    /// once the question has been answered only Settings can change the answer.
    static func requestInputMonitoring() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        let id = deviceID(for: device)
        let key = persistentKey(for: device)
        devices[id] = HIDMouseDevice(
            id: id,
            name: deviceName(for: device),
            persistentKey: key,
            reference: device
        )

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), runLoopMode)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        // Only the saved choice, never a guess. The guess took whichever device macOS happened to
        // list second, which could just as well be the main mouse; with no choice saved, the app
        // asks instead.
        if key == UserDefaults.standard.string(forKey: secondaryDeviceDefaultsKey) {
            secondaryDeviceID = id
        }

        captureSecondaryDevice()
        delegate?.mouseMonitorDevicesChanged(self)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let id = deviceID(for: device)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), runLoopMode)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        devices.removeValue(forKey: id)

        if seizedSecondaryDeviceID == id {
            seizedSecondaryDeviceID = nil
        }

        if secondaryDeviceID == id {
            secondaryDeviceID = nil
        }

        captureSecondaryDevice()
        delegate?.mouseMonitorDevicesChanged(self)
    }

    fileprivate func inputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let deviceID = deviceID(for: IOHIDElementGetDevice(element))

        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        if usagePage == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y, intValue != 0 {
            lastMove = (deviceID, ProcessInfo.processInfo.systemUptime)
        } else if usagePage == kHIDPage_Button, intValue != 0 {
            lastPress = (deviceID, ProcessInfo.processInfo.systemUptime)
        }

        // Only while seized: a blue mouse that macOS still owns also moves the regular pointer,
        // and each of its clicks would land twice, once under each pointer.
        guard deviceID == seizedSecondaryDeviceID else {
            return
        }

        switch (Int(usagePage), Int(usage)) {
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_X)):
            accumulate(CGPoint(x: intValue, y: 0))
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_Y)):
            accumulate(CGPoint(x: 0, y: intValue))
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_Wheel)):
            scroll(CGPoint(x: 0, y: intValue))
        case (Int(kHIDPage_Consumer), 0x238): // AC Pan, the horizontal wheel / tilt.
            scroll(CGPoint(x: intValue, y: 0))
        case (Int(kHIDPage_Button), 1...32):
            // HID numbers buttons from 1 and Quartz from 0: left, right, middle, then the side ones.
            if let button = CGMouseButton(rawValue: UInt32(usage - 1)) {
                self.button(button, isPressed: intValue != 0)
            }
        default:
            break
        }
    }

    private func accumulate(_ delta: CGPoint) {
        pendingDelta.x += delta.x
        pendingDelta.y += delta.y

        guard !flushScheduled else {
            return
        }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingMovement()
        }
    }

    private func flushPendingMovement() {
        flushScheduled = false
        let delta = pendingDelta
        pendingDelta = .zero

        guard delta != .zero else {
            return
        }
        delegate?.mouseMonitor(self, didMoveSecondaryBy: delta)
    }

    private func scroll(_ delta: CGPoint) {
        flushPendingMovement()
        delegate?.mouseMonitor(self, didScrollSecondaryBy: delta)
    }

    private func button(_ button: CGMouseButton, isPressed: Bool) {
        // Press and release must land at the position the user actually pointed at.
        flushPendingMovement()
        delegate?.mouseMonitor(self, didChangeSecondaryButton: button, isPressed: isPressed)
    }

    // The IOService registry ID is unique per connected device and, unlike an object
    // address, is never handed to a different device after an unplug.
    private func deviceID(for device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    // Survives relaunches, unlike the registry ID. Same port, same key.
    private func persistentKey(for device: IOHIDDevice) -> String {
        let number = { (key: String) -> Int in
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        return "\(number(kIOHIDVendorIDKey)):\(number(kIOHIDProductIDKey)):\(number(kIOHIDLocationIDKey))"
    }

    private func deviceName(for device: IOHIDDevice) -> String {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        let base = [manufacturer, product].compactMap { $0 }.joined(separator: " ")
        let label = base.isEmpty ? "Pointing Device" : base

        if let transport {
            return "\(label) (\(transport))"
        }
        return label
    }

}

struct HIDMouseDevice {
    let id: UInt64
    let name: String
    let persistentKey: String
    let reference: IOHIDDevice
}

private func mouseMonitor(from context: UnsafeMutableRawPointer?) -> HIDMouseMonitor {
    Unmanaged<HIDMouseMonitor>.fromOpaque(context!).takeUnretainedValue()
}

private let deviceAddedCallback: IOHIDDeviceCallback = { context, _, _, device in
    mouseMonitor(from: context).deviceAdded(device)
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    mouseMonitor(from: context).deviceRemoved(device)
}

private let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
    mouseMonitor(from: context).inputValue(value)
}
