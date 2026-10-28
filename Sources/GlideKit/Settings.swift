import Foundation

public enum Smoothness: String, Codable, CaseIterable, Sendable {
    case off, low, medium, high
    public var title: String { rawValue.capitalized }
}

public enum ScrollSpeed: String, Codable, CaseIterable, Sendable {
    case slow, medium, fast
    public var title: String { rawValue.capitalized }
}

/// What a held keyboard modifier does to the mouse wheel.
public enum ScrollModifierAction: String, Codable, CaseIterable, Sendable {
    case none, zoom, precise, horizontal, swift
    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .zoom: return "Zoom"
        case .precise: return "Precise"
        case .horizontal: return "Horizontal"
        case .swift: return "Swift"
        }
    }
}

/// Mouse buttons in user numbering: 3 = middle, 4 = back side button, 5 = forward side button.
/// CGEvent's `mouseEventButtonNumber` is this minus one.
public enum MouseButton: Int, Codable, CaseIterable, Sendable {
    case middle = 3, button4 = 4, button5 = 5
    public var cgButtonNumber: Int64 { Int64(rawValue - 1) }
    public init?(cgButtonNumber: Int64) { self.init(rawValue: Int(cgButtonNumber) + 1) }
    public var title: String { "Button \(rawValue)" }
}

public enum ButtonTrigger: String, Codable, CaseIterable, Sendable {
    case click, doubleClick, hold
    public var title: String {
        switch self { case .click: return "Click"; case .doubleClick: return "Double Click"; case .hold: return "Hold" }
    }
}

/// A keyboard shortcut: Carbon/CG virtual key code + CGEventFlags raw modifier bits.
public struct KeyShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public init(keyCode: UInt16, modifiers: UInt64) { self.keyCode = keyCode; self.modifiers = modifiers }
}

public enum ButtonAction: Codable, Equatable, Hashable, Sendable {
    case none
    case missionControl, appExpose, showDesktop, launchpad
    case back, forward
    case smartZoom
    case middleClick
    case shortcut(KeyShortcut)

    public static let menuCases: [ButtonAction] = [
        .none, .missionControl, .appExpose, .showDesktop, .launchpad, .back, .forward, .smartZoom, .middleClick,
    ]

    public var title: String {
        switch self {
        case .none: return "None"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .back: return "Back"
        case .forward: return "Forward"
        case .smartZoom: return "Smart Zoom"
        case .middleClick: return "Middle Click"
        case .shortcut(let s): return "Shortcut " + ShortcutFormatter.string(s)
        }
    }
}

public struct ButtonRemap: Codable, Equatable, Hashable, Sendable {
    public var button: MouseButton
    public var trigger: ButtonTrigger
    public var action: ButtonAction
    public init(button: MouseButton, trigger: ButtonTrigger, action: ButtonAction) {
        self.button = button; self.trigger = trigger; self.action = action
    }
}

/// Per-app override, matched on bundle identifier.
public struct AppException: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var disableSmoothing: Bool
    public init(bundleID: String, name: String, disableSmoothing: Bool = true) {
        self.bundleID = bundleID; self.name = name; self.disableSmoothing = disableSmoothing
    }
}

public struct ScrollModifiers: Codable, Equatable, Sendable {
    public var command: ScrollModifierAction = .zoom
    public var option: ScrollModifierAction = .precise
    public var shift: ScrollModifierAction = .horizontal
    public var control: ScrollModifierAction = .swift
    public init() {}
}

/// Every user setting. Defaults reproduce Melvern's Mac Mouse Fix setup.
/// Decoding is tolerant: a missing or malformed key falls back to its default instead of
/// throwing away the whole file.
public struct GlideSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var smoothness: Smoothness = .high
    public var speed: ScrollSpeed = .medium
    /// true = the mouse wheel scrolls "naturally" like the trackpad, whatever the system setting is.
    public var reverseDirection = true
    public var trackpadSimulation = true
    public var modifiers = ScrollModifiers()

    public var remapsEnabled = false
    public var remaps: [ButtonRemap] = []
    /// Hold this button + drag = three-finger swipe (Spaces / Mission Control). nil = off.
    public var dragGestureButton: MouseButton? = nil
    /// Hold this button + scroll = pinch to zoom. nil = off.
    public var scrollGestureButton: MouseButton? = nil

    public var exceptions: [AppException] = []
    public var launchAtLogin = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, smoothness, speed, reverseDirection, trackpadSimulation, modifiers
        case remapsEnabled, remaps, dragGestureButton, scrollGestureButton, exceptions, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let d = GlideSettings()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        enabled = v(.enabled, d.enabled)
        smoothness = v(.smoothness, d.smoothness)
        speed = v(.speed, d.speed)
        reverseDirection = v(.reverseDirection, d.reverseDirection)
        trackpadSimulation = v(.trackpadSimulation, d.trackpadSimulation)
        modifiers = v(.modifiers, d.modifiers)
        remapsEnabled = v(.remapsEnabled, d.remapsEnabled)
        // Drop individual malformed remaps instead of failing the list.
        if let raw = try? c.decodeIfPresent([Lenient<ButtonRemap>].self, forKey: .remaps) {
            remaps = raw.compactMap(\.value)
        }
        dragGestureButton = (try? c.decodeIfPresent(MouseButton.self, forKey: .dragGestureButton)) ?? nil
        scrollGestureButton = (try? c.decodeIfPresent(MouseButton.self, forKey: .scrollGestureButton)) ?? nil
        if let raw = try? c.decodeIfPresent([Lenient<AppException>].self, forKey: .exceptions) {
            exceptions = raw.compactMap(\.value).filter { !$0.bundleID.isEmpty }
        }
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
    }

    /// Remaps that apply right now (empty when remaps are switched off).
    public var activeRemaps: [ButtonRemap] { remapsEnabled ? remaps : [] }

    public func smoothingDisabled(forBundleID id: String?) -> Bool {
        guard let id else { return false }
        return exceptions.contains { $0.bundleID == id && $0.disableSmoothing }
    }

    /// Buttons Glide has to intercept (anything else passes through untouched).
    public var interceptedButtons: Set<MouseButton> {
        var s = Set(activeRemaps.filter { $0.action != .none }.map(\.button))
        if let b = dragGestureButton { s.insert(b) }
        if let b = scrollGestureButton { s.insert(b) }
        return s
    }
}

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Persists settings as one JSON blob in a UserDefaults domain (injected so tests use a throwaway suite).
public final class SettingsStore {
    public static let key = "settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> GlideSettings {
        guard let data = defaults.data(forKey: Self.key) else { return GlideSettings() }
        return (try? JSONDecoder().decode(GlideSettings.self, from: data)) ?? GlideSettings()
    }

    public func save(_ s: GlideSettings) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }
}

public enum ShortcutFormatter {
    static let names: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 27: "-", 24: "=", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
    // CGEventFlags bits
    public static let control: UInt64 = 1 << 18, option: UInt64 = 1 << 19, shift: UInt64 = 1 << 17, command: UInt64 = 1 << 20

    public static func string(_ s: KeyShortcut) -> String {
        var out = ""
        if s.modifiers & control != 0 { out += "⌃" }
        if s.modifiers & option != 0 { out += "⌥" }
        if s.modifiers & shift != 0 { out += "⇧" }
        if s.modifiers & command != 0 { out += "⌘" }
        return out + (names[s.keyCode] ?? "key\(s.keyCode)")
    }
}
