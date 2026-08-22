import AppKit
import ApplicationServices

@MainActor
final class TextInsertionService {
    struct Destination {
        let element: AXUIElement
        let processIdentifier: pid_t
        let pasteMenuItem: AXUIElement?
    }

    enum Strategy: String { case pasteMenu, keyboardPaste, accessibilityText, clipboardRecovery }
    struct Result { let strategy: Strategy; let inserted: Bool }

    private struct TextSnapshot {
        let value: String?
        let characterCount: Int?

        var isObservable: Bool { value != nil || characterCount != nil }
    }

    func captureDestination() -> Destination? {
        guard let element = focusedElement(), isEditableTextInput(element) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        let application = AXUIElementCreateApplication(pid)
        let pasteItem = elementAttribute(kAXMenuBarAttribute as CFString, of: application)
            .flatMap { pasteMenuItem(in: $0, depth: 0, requiresEnabled: false) }
        return Destination(element: element, processIdentifier: pid,
                           pasteMenuItem: pasteItem)
    }

    func insert(_ text: String, at destination: Destination?) async -> Result {
        let copied = copyToClipboard(text)
        let recovery = Result(strategy: Strategy.clipboardRecovery, inserted: false)
        guard copied, let destination else { return recovery }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            return recovery
        }
        guard let focused = focusedElement(), CFEqual(focused, destination.element),
              isEditableTextInput(focused) else { return recovery }
        let before = snapshot(of: focused)

        if performPasteCommand(at: destination) {
            if await insertionWasObserved(from: before, in: focused) {
                return Result(strategy: .pasteMenu, inserted: true)
            }
        }
        if dispatchPaste() {
            if await insertionWasObserved(from: before, in: focused) {
                return Result(strategy: .keyboardPaste, inserted: true)
            }
        }
        if AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString,
                                        text as CFString) == .success {
            if await insertionWasObserved(from: before, in: focused) {
                return Result(strategy: .accessibilityText, inserted: true)
            }
        }
        return recovery
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func isEditableTextInput(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
        guard role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" else { return false }
        guard stringAttribute(kAXSubroleAttribute as CFString, of: element) != "AXSecureTextField" else {
            return false
        }
        guard boolAttribute(kAXFocusedAttribute as CFString, of: element) != false,
              boolAttribute(kAXEnabledAttribute as CFString, of: element) != false else { return false }
        return true
    }

    private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func snapshot(of element: AXUIElement) -> TextSnapshot {
        TextSnapshot(
            value: stringAttribute(kAXValueAttribute as CFString, of: element),
            characterCount: numberAttribute(kAXNumberOfCharactersAttribute as CFString,
                                            of: element)?.intValue
        )
    }

    private func insertedTextChanged(from before: TextSnapshot, in element: AXUIElement) -> Bool {
        let after = snapshot(of: element)
        if let beforeValue = before.value, let afterValue = after.value,
           beforeValue != afterValue { return true }
        if let beforeCount = before.characterCount, let afterCount = after.characterCount,
           beforeCount != afterCount { return true }
        return false
    }

    private func insertionWasObserved(from before: TextSnapshot, in element: AXUIElement) async -> Bool {
        guard before.isObservable else { return true }
        if insertedTextChanged(from: before, in: element) { return true }
        try? await Task.sleep(for: .milliseconds(40))
        return insertedTextChanged(from: before, in: element)
    }

    private func performPasteCommand(at destination: Destination) -> Bool {
        if let pasteItem = destination.pasteMenuItem,
           AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success {
            return true
        }
        let application = AXUIElementCreateApplication(destination.processIdentifier)
        guard let menuBar = elementAttribute(kAXMenuBarAttribute as CFString, of: application),
              let pasteItem = pasteMenuItem(in: menuBar, depth: 0, requiresEnabled: true) else { return false }
        return AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success
    }

    private func pasteMenuItem(in element: AXUIElement, depth: Int,
                               requiresEnabled: Bool) -> AXUIElement? {
        guard depth <= 5 else { return nil }
        if stringAttribute(kAXRoleAttribute as CFString, of: element) == "AXMenuItem",
           (!requiresEnabled || boolAttribute(kAXEnabledAttribute as CFString, of: element) != false) {
            let key = numberAttribute(kAXMenuItemCmdVirtualKeyAttribute as CFString, of: element)?.intValue
            let character = stringAttribute(kAXMenuItemCmdCharAttribute as CFString, of: element)?.lowercased()
            let modifiers = numberAttribute(kAXMenuItemCmdModifiersAttribute as CFString,
                                            of: element)?.uint32Value
            if modifiers == 0, key == 9 || character == "v" { return element }
        }
        for child in elementArrayAttribute(kAXChildrenAttribute as CFString, of: element) {
            if let found = pasteMenuItem(in: child, depth: depth + 1,
                                         requiresEnabled: requiresEnabled) { return found }
        }
        return nil
    }

    private func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ attribute: CFString, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let values = value as? [AXUIElement] else { return [] }
        return values
    }

    private func numberAttribute(_ attribute: CFString, of element: AXUIElement) -> NSNumber? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? NSNumber
    }

    private func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func dispatchPaste() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let pasteDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let pasteUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else {
            return false
        }
        commandDown.flags = .maskCommand
        pasteDown.flags = .maskCommand
        pasteUp.flags = .maskCommand
        commandUp.flags = []
        commandDown.post(tap: .cgSessionEventTap)
        pasteDown.post(tap: .cgSessionEventTap)
        pasteUp.post(tap: .cgSessionEventTap)
        commandUp.post(tap: .cgSessionEventTap)
        return true
    }
}
