import AppKit
import ApplicationServices
import os
import WaveCore

final class HotkeyService: @unchecked Sendable {
    enum Action: Sendable { case pressed, released, lockToggled, meetingToggled, cancelled }
    var handler: (@Sendable (Action) -> Void)?

    private struct EventState: Sendable {
        var triggerIsDown = false
        var lockChordIsDown = false
        var cancellationEnabled = false
        var escapeIsDown = false
        var meetingChordIsDown = false
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let binding = OSAllocatedUnfairLock(initialState: HoldShortcut.functionKey)
    private let eventState = OSAllocatedUnfairLock(initialState: EventState())
    private let logger = Logger(subsystem: "com.keyer.app", category: "hotkey")

    func updateBinding(_ shortcut: HoldShortcut) {
        binding.withLock { $0 = shortcut }
        let shouldRelease = eventState.withLock { state in
            let wasDown = state.triggerIsDown
            state.triggerIsDown = false
            state.lockChordIsDown = false
            return wasDown
        }
        if shouldRelease { handler?(.released) }
    }

    func setCancellationEnabled(_ enabled: Bool) {
        eventState.withLock { $0.cancellationEnabled = enabled }
    }

    func start() -> Bool {
        if let eventTap {
            if CGEvent.tapIsEnabled(tap: eventTap) { return true }
            let shouldRelease = eventState.withLock { $0.triggerIsDown }
            stop()
            if shouldRelease { handler?(.released) }
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .defaultTap,
                                    eventsOfInterest: mask,
                                    callback: waveEventTapCallback,
                                    userInfo: context)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: .listenOnly,
                                 eventsOfInterest: mask,
                                 callback: waveEventTapCallback,
                                 userInfo: context)
        guard let tap else {
            logger.error("Event tap creation failed; inputMonitoring=\(CGPreflightListenEventAccess(), privacy: .public)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        logger.notice("Event tap started; enabled=\(enabled, privacy: .public)")
        return enabled
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        runLoopSource = nil
        eventTap = nil
        eventState.withLock {
            $0.triggerIsDown = false
            $0.lockChordIsDown = false
            $0.cancellationEnabled = false
            $0.escapeIsDown = false
            $0.meetingChordIsDown = false
        }
    }

    /// Returns true only when Keyer owns the Escape event and it should not reach the frontmost app.
    fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let shouldRelease = eventState.withLock { state in
                let wasDown = state.triggerIsDown
                state.triggerIsDown = false
                state.lockChordIsDown = false
                state.escapeIsDown = false
                return wasDown
            }
            logger.warning("Event tap was disabled by macOS; attempting to re-enable it")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            if shouldRelease { handler?(.released) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 46 {
            let currentModifiers = modifiers(for: event.flags)
            if type == .keyDown, currentModifiers == [.control, .option] {
                let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let shouldToggle = eventState.withLock { state in
                    guard !state.meetingChordIsDown, !isAutorepeat else { return false }
                    state.meetingChordIsDown = true
                    return true
                }
                if shouldToggle { handler?(.meetingToggled) }
                return true
            }
            if type == .keyUp {
                return eventState.withLock { state in
                    let shouldSwallow = state.meetingChordIsDown
                    state.meetingChordIsDown = false
                    return shouldSwallow
                }
            }
        }
        if keyCode == 53 {
            if type == .keyDown {
                let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let shouldCancel = eventState.withLock { state in
                    guard state.cancellationEnabled else { return false }
                    let isFirstPress = !state.escapeIsDown && !isAutorepeat
                    state.escapeIsDown = true
                    return isFirstPress
                }
                if shouldCancel { handler?(.cancelled) }
                return shouldCancel || eventState.withLock { $0.escapeIsDown }
            }
            if type == .keyUp {
                return eventState.withLock { state in
                    let shouldSwallow = state.escapeIsDown
                    state.escapeIsDown = false
                    return shouldSwallow
                }
            }
        }

        let shortcut = binding.withLock { $0 }
        if shortcut.kind == .functionKey {
            let functionKeyCode: Int64 = 63
            let isDown: Bool?
            if type == .flagsChanged {
                isDown = event.flags.contains(.maskSecondaryFn)
            } else if keyCode == functionKeyCode, type == .keyDown {
                isDown = true
            } else if keyCode == functionKeyCode, type == .keyUp {
                isDown = false
            } else {
                isDown = nil
            }

            guard let isDown else { return false }
            let currentModifiers = modifiers(for: event.flags)
            let action = eventState.withLock { state -> Action? in
                if state.lockChordIsDown {
                    if !isDown { state.lockChordIsDown = false }
                    return nil
                }
                if isDown, currentModifiers == shortcut.lockModifiers {
                    state.lockChordIsDown = true
                    state.triggerIsDown = false
                    return .lockToggled
                }
                guard isDown != state.triggerIsDown else { return nil }
                state.triggerIsDown = isDown
                return isDown ? .pressed : .released
            }
            if let action { handler?(action) }
            return false
        }

        guard shortcut.kind == .keyboard,
              keyCode == shortcut.keyCode.map(Int64.init),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }

        if type == .keyDown, modifiers(for: event.flags) == shortcut.lockModifiers {
            let shouldToggle = eventState.withLock { state in
                guard !state.lockChordIsDown else { return false }
                state.lockChordIsDown = true
                state.triggerIsDown = false
                return true
            }
            if shouldToggle { handler?(.lockToggled) }
        } else if type == .keyUp, eventState.withLock({ $0.lockChordIsDown }) {
            eventState.withLock { $0.lockChordIsDown = false }
        } else if type == .keyDown, modifiers(for: event.flags) == shortcut.modifiers {
            let changed = eventState.withLock { state in
                guard !state.triggerIsDown else { return false }
                state.triggerIsDown = true
                return true
            }
            if changed { handler?(.pressed) }
        } else if type == .keyUp {
            let changed = eventState.withLock { state in
                guard state.triggerIsDown else { return false }
                state.triggerIsDown = false
                return true
            }
            if changed { handler?(.released) }
        }
        return false
    }

    private func modifiers(for flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }
}

private func waveEventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.process(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
