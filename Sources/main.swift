// instaswitch — switch the keyboard layout instantly with Caps Lock.
//
// Caps Lock is remapped to F18 at the HID level (hidutil), then an event tap
// catches F18 on key down and selects the next enabled input source right away:
// no tap/hold detection, no waiting for key up, modifiers are ignored.
// Shift+Caps Lock toggles the real Caps Lock.

import Carbon
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

let capsLockUsage: UInt64 = 0x7_0000_0039
let f18Usage: UInt64 = 0x7_0000_006D
let f18KeyCode: Int64 = 79 // kVK_F18

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}

// MARK: - Caps Lock -> F18 mapping

enum KeyMapping {
    private static let queue = DispatchQueue(label: "instaswitch.hidutil")

    static func apply() {
        let json = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\#(capsLockUsage),"HIDKeyboardModifierMappingDst":\#(f18Usage)}]}"#
        hidutil(json)
    }

    static func clear() {
        hidutil(#"{"UserKeyMapping":[]}"#)
    }

    private static func hidutil(_ json: String) {
        queue.sync {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            process.arguments = ["property", "--set", json]
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    log("hidutil exited with \(process.terminationStatus)")
                }
            } catch {
                log("hidutil failed: \(error)")
            }
        }
    }
}

/// Re-applies the mapping whenever a HID device appears (new keyboard, wake, reconnect).
final class DeviceWatcher {
    private let port = IONotificationPortCreate(kIOMainPortDefault)
    private var iterator: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    init() {
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            let watcher = Unmanaged<DeviceWatcher>.fromOpaque(refcon!).takeUnretainedValue()
            if watcher.drain(iterator) { watcher.scheduleApply() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
                                         callback, Unmanaged.passUnretained(self).toOpaque(), &iterator)
        _ = drain(iterator) // arm the notification; existing devices are covered by the initial apply
    }

    private func drain(_ iterator: io_iterator_t) -> Bool {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            found = true
        }
        return found
    }

    private func scheduleApply() {
        pending?.cancel()
        let work = DispatchWorkItem { KeyMapping.apply() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - Input sources

final class InputSources {
    private var sources: [TISInputSource] = []

    init() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    func reload() {
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable: true,
        ] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        let switchable = [kTISTypeKeyboardLayout as String, kTISTypeKeyboardInputMode as String]
        sources = list.filter { source in
            guard let type: String = property(source, kTISPropertyInputSourceType) else { return false }
            return switchable.contains(type) && property(source, kTISPropertyInputSourceIsEnabled) == true
        }
        log("input sources: " + sources.compactMap { property($0, kTISPropertyInputSourceID) as String? }.joined(separator: ", "))
    }

    func selectNext() {
        guard sources.count > 1 else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentID: String? = property(current, kTISPropertyInputSourceID)
        let index = sources.firstIndex { property($0, kTISPropertyInputSourceID) == currentID } ?? -1
        let next = sources[(index + 1) % sources.count]
        let status = TISSelectInputSource(next)
        if status != noErr { log("TISSelectInputSource failed: \(status)") }
    }

    private func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

// MARK: - Caps Lock state

enum CapsLock {
    static func toggle() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var state = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    }
}

// MARK: - Event tap

let inputSources = InputSources()
var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.keyboardEventKeycode) == f18KeyCode else {
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        if event.flags.contains(.maskShift) {
            DispatchQueue.main.async { CapsLock.toggle() }
        } else {
            DispatchQueue.main.async { inputSources.selectNext() }
        }
    }
    return nil // swallow F18 so no app ever sees it
}

func installTap() -> Bool {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        return false
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - Startup

var deviceWatcher: DeviceWatcher?

func start() {
    // Remap Caps Lock only once the tap works, so the key never ends up dead.
    KeyMapping.apply()
    deviceWatcher = DeviceWatcher()
    log("running")
}

if installTap() {
    start()
} else {
    log("no permission for event tap, waiting for Accessibility / Input Monitoring")
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    _ = CGRequestListenEventAccess()
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
        if installTap() {
            timer.invalidate()
            start()
        }
    }
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        KeyMapping.clear() // give Caps Lock back
        log("stopped by signal \(sig)")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

CFRunLoopRun()
