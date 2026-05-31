import AppKit
import IOKit.hid

protocol HIDMouseMonitorDelegate: AnyObject {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMovePrimaryBy delta: CGPoint)
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint)
    func mouseMonitorDidSecondaryClick(_ monitor: HIDMouseMonitor, clickCount: Int)
    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor)
}

final class HIDMouseMonitor {
    enum AssignmentTarget {
        case primary
        case secondary
    }

    weak var delegate: HIDMouseMonitorDelegate?

    private var manager: IOHIDManager!
    private var devices: [UInt64: HIDMouseDevice] = [:]
    private var primaryDeviceID: UInt64?
    private var secondaryDeviceID: UInt64?
    private var pendingAssignment: AssignmentTarget?
    private var lastSecondaryClickAt: Date?
    private var secondaryClickCount = 0
    private(set) var secondaryEventCount = 0

    var secondaryDeviceName: String? {
        guard let secondaryDeviceID else {
            return nil
        }
        return devices[secondaryDeviceID]?.name
    }

    var primaryDeviceName: String? {
        guard let primaryDeviceID else {
            return nil
        }
        return devices[primaryDeviceID]?.name
    }

    var allDevices: [HIDMouseDevice] {
        devices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedPrimaryDeviceID: UInt64? {
        primaryDeviceID
    }

    var selectedSecondaryDeviceID: UInt64? {
        secondaryDeviceID
    }

    init(delegate: HIDMouseMonitorDelegate?) {
        self.delegate = delegate
    }

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

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
        IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setPrimaryDevice(id: UInt64) {
        guard devices[id] != nil else {
            return
        }

        primaryDeviceID = id
        if secondaryDeviceID == id {
            secondaryDeviceID = devices.keys.first(where: { $0 != id })
        }
        delegate?.mouseMonitorDevicesChanged(self)
    }

    func setSecondaryDevice(id: UInt64) {
        guard devices[id] != nil else {
            return
        }

        secondaryDeviceID = id
        if primaryDeviceID == id {
            primaryDeviceID = devices.keys.first(where: { $0 != id })
        }
        delegate?.mouseMonitorDevicesChanged(self)
    }

    func assignDeviceFromNextMovement(_ target: AssignmentTarget) {
        pendingAssignment = target
        delegate?.mouseMonitorDevicesChanged(self)
    }

    var assignmentPrompt: String? {
        guard let pendingAssignment else {
            return nil
        }

        return switch pendingAssignment {
        case .primary:
            "Move the system mouse now"
        case .secondary:
            "Move the blue pointer mouse now"
        }
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        let id = registryID(for: device)
        devices[id] = HIDMouseDevice(
            id: id,
            name: deviceName(for: device)
        )

        if primaryDeviceID == nil {
            primaryDeviceID = id
        } else if secondaryDeviceID == nil && primaryDeviceID != id {
            secondaryDeviceID = id
        }

        delegate?.mouseMonitorDevicesChanged(self)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let id = registryID(for: device)
        devices.removeValue(forKey: id)

        if secondaryDeviceID == id {
            secondaryDeviceID = devices.keys.first(where: { $0 != primaryDeviceID })
        }
        if primaryDeviceID == id {
            primaryDeviceID = devices.keys.first
        }

        delegate?.mouseMonitorDevicesChanged(self)
    }

    fileprivate func inputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let deviceID = registryID(for: device)

        if primaryDeviceID == nil {
            primaryDeviceID = deviceID
        } else if secondaryDeviceID == nil && primaryDeviceID != deviceID {
            secondaryDeviceID = deviceID
            delegate?.mouseMonitorDevicesChanged(self)
        }

        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        guard usagePage == kHIDPage_GenericDesktop || usagePage == kHIDPage_Button else {
            return
        }

        if let pendingAssignment,
           usagePage == kHIDPage_GenericDesktop,
           (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y),
           intValue != 0 {
            switch pendingAssignment {
            case .primary:
                setPrimaryDevice(id: deviceID)
            case .secondary:
                setSecondaryDevice(id: deviceID)
            }
            self.pendingAssignment = nil
            delegate?.mouseMonitorDevicesChanged(self)
            return
        }

        if deviceID == secondaryDeviceID {
            secondaryEventCount += 1
            handleSecondaryInput(usagePage: usagePage, usage: usage, value: intValue)
        } else if deviceID == primaryDeviceID {
            handlePrimaryInput(usagePage: usagePage, usage: usage, value: intValue)
        }
    }

    private func handlePrimaryInput(usagePage: UInt32, usage: UInt32, value: CFIndex) {
        guard usagePage == kHIDPage_GenericDesktop else {
            return
        }

        if usage == kHIDUsage_GD_X {
            delegate?.mouseMonitor(self, didMovePrimaryBy: CGPoint(x: value, y: 0))
        } else if usage == kHIDUsage_GD_Y {
            delegate?.mouseMonitor(self, didMovePrimaryBy: CGPoint(x: 0, y: value))
        }
    }

    private func handleSecondaryInput(usagePage: UInt32, usage: UInt32, value: CFIndex) {
        if usagePage == kHIDPage_GenericDesktop {
            if usage == kHIDUsage_GD_X {
                delegate?.mouseMonitor(self, didMoveSecondaryBy: CGPoint(x: value, y: 0))
            } else if usage == kHIDUsage_GD_Y {
                delegate?.mouseMonitor(self, didMoveSecondaryBy: CGPoint(x: 0, y: value))
            }
            return
        }

        guard usagePage == kHIDPage_Button, usage == 1, value == 1 else {
            return
        }

        let now = Date()
        if let lastSecondaryClickAt, now.timeIntervalSince(lastSecondaryClickAt) < 0.45 {
            secondaryClickCount += 1
        } else {
            secondaryClickCount = 1
        }
        lastSecondaryClickAt = now

        delegate?.mouseMonitorDidSecondaryClick(self, clickCount: secondaryClickCount)
    }

    private func registryID(for device: IOHIDDevice) -> UInt64 {
        var registryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0, IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS {
            return registryID
        }

        if let property = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) {
            let number = property as! NSNumber
            return number.uint64Value
        }
        return UInt64(bitPattern: Int64(ObjectIdentifier(device).hashValue))
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
