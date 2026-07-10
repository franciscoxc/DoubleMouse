import AppKit
import IOKit.hid

protocol HIDMouseMonitorDelegate: AnyObject {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: Int32)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton isPressed: Bool)
    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor)
}

final class HIDMouseMonitor {
    weak var delegate: HIDMouseMonitorDelegate?

    private var manager: IOHIDManager!
    private var devices: [UInt64: HIDMouseDevice] = [:]
    private var deviceIDsByObject: [ObjectIdentifier: UInt64] = [:]
    private var nextDeviceObjectID: UInt64 = 1
    private var secondaryDeviceID: UInt64?
    private var seizedSecondaryDeviceID: UInt64?
    private var awaitingSecondaryAssignment = false

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
        guard devices[id] != nil else {
            return
        }

        secondaryDeviceID = id
        captureSecondaryDevice()
        delegate?.mouseMonitorDevicesChanged(self)
    }

    func assignSecondaryDeviceFromNextMovement() {
        awaitingSecondaryAssignment = true
        delegate?.mouseMonitorDevicesChanged(self)
    }

    var assignmentPrompt: String? {
        awaitingSecondaryAssignment ? "Move the blue pointer mouse now" : nil
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        let id = deviceObjectID(for: device)
        devices[id] = HIDMouseDevice(
            id: id,
            name: deviceName(for: device),
            reference: device
        )

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        if secondaryDeviceID == nil && devices.count >= 2 {
            secondaryDeviceID = id
        }

        captureSecondaryDevice()
        delegate?.mouseMonitorDevicesChanged(self)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let id = deviceObjectID(for: device)
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
        let device = IOHIDElementGetDevice(element)
        let deviceID = deviceObjectID(for: device)

        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        guard usagePage == kHIDPage_GenericDesktop || usagePage == kHIDPage_Button else {
            return
        }

        if awaitingSecondaryAssignment,
           usagePage == kHIDPage_GenericDesktop,
           (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y),
           intValue != 0 {
            awaitingSecondaryAssignment = false
            setSecondaryDevice(id: deviceID)
            delegate?.mouseMonitorDevicesChanged(self)
            return
        }

        if deviceID == secondaryDeviceID {
            handleSecondaryInput(usagePage: usagePage, usage: usage, value: intValue)
        }
    }

    private func handleSecondaryInput(usagePage: UInt32, usage: UInt32, value: CFIndex) {
        if usagePage == kHIDPage_GenericDesktop {
            if usage == kHIDUsage_GD_X {
                delegate?.mouseMonitor(self, didMoveSecondaryBy: CGPoint(x: value, y: 0))
            } else if usage == kHIDUsage_GD_Y {
                delegate?.mouseMonitor(self, didMoveSecondaryBy: CGPoint(x: 0, y: value))
            } else if usage == kHIDUsage_GD_Wheel {
                delegate?.mouseMonitor(self, didScrollSecondaryBy: Int32(clamping: value))
            }
            return
        }

        guard usagePage == kHIDPage_Button, usage == 1 else {
            return
        }
        delegate?.mouseMonitor(self, didChangeSecondaryButton: value != 0)
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

    private func deviceObjectID(for device: IOHIDDevice) -> UInt64 {
        let objectID = ObjectIdentifier(device)
        if let id = deviceIDsByObject[objectID] {
            return id
        }

        let id = nextDeviceObjectID
        nextDeviceObjectID += 1
        deviceIDsByObject[objectID] = id
        return id
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
