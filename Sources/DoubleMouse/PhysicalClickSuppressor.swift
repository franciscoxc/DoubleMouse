import CoreGraphics
import Foundation

final class PhysicalClickSuppressor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingLeftMouseDown = 0
    private var pendingLeftMouseUp = 0
    private var suppressUntil = Date.distantPast

    func start() {
        guard eventTap == nil else {
            return
        }

        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue)

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: clickSuppressorCallback,
            userInfo: userInfo
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func suppressNextLeftClick() {
        pendingLeftMouseDown += 1
        pendingLeftMouseUp += 1
        suppressUntil = Date().addingTimeInterval(0.20)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(CGEventField(rawValue: 42)!) == EventMarker.doubleMouseSyntheticClick {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard Date() < suppressUntil else {
            pendingLeftMouseDown = 0
            pendingLeftMouseUp = 0
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown, pendingLeftMouseDown > 0 {
            pendingLeftMouseDown -= 1
            return nil
        }

        if type == .leftMouseUp, pendingLeftMouseUp > 0 {
            pendingLeftMouseUp -= 1
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private let clickSuppressorCallback: CGEventTapCallBack = { _, type, event, userInfo in
    let suppressor = Unmanaged<PhysicalClickSuppressor>.fromOpaque(userInfo!).takeUnretainedValue()
    return suppressor.handle(type: type, event: event)
}
