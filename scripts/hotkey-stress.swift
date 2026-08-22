import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let cycles = arguments.count > 1 ? Int(arguments[1]) ?? 1_000 : 1_000
let holdMicroseconds = arguments.count > 2 ? useconds_t(arguments[2]) ?? 2_000 : 2_000
let gapMicroseconds = arguments.count > 3 ? useconds_t(arguments[3]) ?? 2_000 : 2_000
let mode = arguments.count > 4 ? arguments[4] : "flags"

guard let source = CGEventSource(stateID: .hidSystemState) else {
    fatalError("Could not create a HID event source")
}

func postFunctionFlags(_ flags: CGEventFlags) {
    guard let event = CGEvent(source: source) else { return }
    event.type = .flagsChanged
    event.setIntegerValueField(.keyboardEventKeycode, value: 63)
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func postFunctionKey(isDown: Bool) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: isDown) else { return }
    event.flags = isDown ? .maskSecondaryFn : []
    event.post(tap: .cghidEventTap)
}

for _ in 0..<cycles {
    if mode == "key" {
        postFunctionKey(isDown: true)
    } else {
        postFunctionFlags(.maskSecondaryFn)
    }
    usleep(holdMicroseconds)
    if mode == "key" {
        postFunctionKey(isDown: false)
    } else {
        postFunctionFlags([])
    }
    usleep(gapMicroseconds)
}

print("Posted \(cycles) Fn press/release cycles using \(mode) events")
