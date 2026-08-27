import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let function = Self(rawValue: 1 << 4)
}

public struct HoldShortcut: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case functionKey
        case keyboard
    }

    public let kind: Kind
    public let keyCode: UInt16?
    public let modifiers: ShortcutModifiers
    public let keyLabel: String

    public static let functionKey = Self(
        kind: .functionKey,
        keyCode: nil,
        modifiers: .function,
        keyLabel: "fn"
    )

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyLabel: String) {
        self.init(kind: .keyboard, keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel)
    }

    private init(kind: Kind, keyCode: UInt16?, modifiers: ShortcutModifiers, keyLabel: String) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayTokens: [String] {
        Self.displayTokens(for: modifiers, keyLabel: keyLabel)
    }

    public var lockModifier: ShortcutModifiers {
        if !modifiers.contains(.command) { return .command }
        if !modifiers.contains(.option) { return .option }
        if !modifiers.contains(.shift) { return .shift }
        return .control
    }

    public var lockModifiers: ShortcutModifiers {
        modifiers.union(lockModifier)
    }

    public var lockDisplayTokens: [String] {
        Self.displayTokens(for: lockModifiers, keyLabel: keyLabel)
    }

    private static func displayTokens(for modifiers: ShortcutModifiers, keyLabel: String) -> [String] {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens.append("⌃") }
        if modifiers.contains(.option) { tokens.append("⌥") }
        if modifiers.contains(.shift) { tokens.append("⇧") }
        if modifiers.contains(.command) { tokens.append("⌘") }
        if modifiers.contains(.function), keyLabel != "fn" { tokens.append("fn") }
        tokens.append(keyLabel)
        return tokens
    }
}
