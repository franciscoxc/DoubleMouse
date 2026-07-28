import AppKit
import IOKit.hid

enum MouseButton {
    case left
    case right
}

protocol HIDMouseMonitorDelegate: AnyObject {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: CGPoint)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton button: MouseButton, isPressed: Bool)
    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor)
}

private let secondaryDeviceDefaultsKey = "secondaryDeviceKey"

final class HIDMouseMonitor {
    weak var delegate: HIDMouseMonitorDelegate?

    private var manager: IOHIDManager!
    private var devices: [UInt64: HIDMouseDevice] = [:]
    private var secondaryDeviceID: UInt64?
    private var seizedSecondaryDeviceID: UInt64?
    private var awaitingSecondaryAssignment = false

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

    var assignmentPrompt: String? {
        awaitingSecondaryAssignment ? "Move the blue pointer mouse now" : nil
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
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        for device in devices.values {
            IOHIDDeviceUnscheduleFromRunLoop(device.reference, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device.reference, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedSecondaryDeviceID = nil
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
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

    func assignSecondaryDeviceFromNextMovement() {
        awaitingSecondaryAssignment = true
        delegate?.mouseMonitorDevicesChanged(self)
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
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        // The stored key is always the last explicit choice, so it outranks the guess below
        // no matter what order devices show up in.
        if key == UserDefaults.standard.string(forKey: secondaryDeviceDefaultsKey) {
            secondaryDeviceID = id
        } else if secondaryDeviceID == nil && devices.count >= 2 {
            secondaryDeviceID = id
        }

        captureSecondaryDevice()
        delegate?.mouseMonitorDevicesChanged(self)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let id = deviceID(for: device)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
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

        if awaitingSecondaryAssignment,
           usagePage == kHIDPage_GenericDesktop,
           usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y,
           intValue != 0 {
            awaitingSecondaryAssignment = false
            setSecondaryDevice(id: deviceID)
            return
        }

        guard deviceID == secondaryDeviceID else {
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
        case (Int(kHIDPage_Button), 1):
            button(.left, isPressed: intValue != 0)
        case (Int(kHIDPage_Button), 2):
            button(.right, isPressed: intValue != 0)
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

    private func button(_ button: MouseButton, isPressed: Bool) {
        // Press and release must land at the position the user actually pointed at.
        flushPendingMovement()
        delegate?.mouseMonitor(self, didChangeSecondaryButton: button, isPressed: isPressed)
    }

    private func captureSecondaryDevice() {
        guard seizedSecondaryDeviceID != secondaryDeviceID else {
            return
        }

        if let seizedSecondaryDeviceID, let oldDevice = devices[seizedSecondaryDeviceID]?.reference {
            IOHIDDeviceClose(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDDeviceOpen(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.seizedSecondaryDeviceID = nil
        }

        guard let secondaryDeviceID,
              let device = devices[secondaryDeviceID]?.reference else {
            return
        }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess {
            seizedSecondaryDeviceID = secondaryDeviceID
        } else {
            IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
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
