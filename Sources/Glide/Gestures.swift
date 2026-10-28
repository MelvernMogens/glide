import AppKit
import ApplicationServices
import GlideKit

/// System gestures and one-shot actions: dock swipes (Spaces / Mission Control / pinch),
/// Mission Control & friends, universal Back/Forward, keyboard shortcuts.
enum Gestures {
    // MARK: private API (resolved at runtime; missing symbols disable the feature, never crash)

    private typealias HIDCreate = @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias HIDSetInt = @convention(c) (CFTypeRef, UInt32, Int) -> Void
    private typealias HIDSetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void
    private typealias HIDAppend = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias SetHID = @convention(c) (CGEvent, CFTypeRef) -> Void
    private typealias DockNotify = @convention(c) (CFString, Int32) -> Void

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        let p = dlsym(iokit, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        return p.map { unsafeBitCast($0, to: type) }
    }
    private static let hidCreate = sym("IOHIDEventCreate", HIDCreate.self)
    private static let hidSetInt = sym("IOHIDEventSetIntegerValue", HIDSetInt.self)
    private static let hidSetFloat = sym("IOHIDEventSetFloatValue", HIDSetFloat.self)
    private static let hidAppend = sym("IOHIDEventAppendEvent", HIDAppend.self)
    private static let setHID = sym("SLEventSetIOHIDEvent", SetHID.self)
    private static let dockNotify = sym("CoreDockSendNotification", DockNotify.self)

    static var dockSwipeAvailable: Bool { hidCreate != nil && hidSetInt != nil && hidSetFloat != nil && setHID != nil }

    // IOHID constants
    private static let typeVelocity: UInt32 = 9, typeDockSwipe: UInt32 = 23
    private static func field(_ type: UInt32, _ i: UInt32) -> UInt32 { (type << 16) | i }
    private static let phaseShift: UInt32 = 24

    enum SwipeKind: Int { case horizontal = 1, vertical = 2, pinch = 3 }

    // MARK: dock swipe state (engine thread only)

    private static var originOffset = 0.0
    private static var lastDelta = 0.0
    private static var kind = SwipeKind.horizontal
    private static var active = false

    /// Natural scrolling = trackpad gestures follow the fingers; dock swipes mirror the system setting.
    static var natural: Bool {
        (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }

    /// Begin/continue a dock swipe. `delta` is in "spaces" (1.0 = one full Space / full gesture).
    static func dockSwipe(_ k: SwipeKind, delta d: Double, phase: ScrollPhase) {
        guard dockSwipeAvailable, d.isFinite else { return }
        switch phase {
        case .began:
            kind = k; originOffset = d; active = true
        case .changed:
            guard active, d != 0 else { return }
            originOffset += d
        default:
            break
        }
        lastDelta = d == 0 ? lastDelta : d
        postDock(phase: phase)
    }

    static func endDockSwipe() {
        guard active else { return }
        active = false
        // Swiping back toward the start cancels the transition.
        let ended = (lastDelta >= 0) == (originOffset >= 0)
        let ph: ScrollPhase = ended ? .ended : .cancelled
        postDock(phase: ph)
        // The system occasionally drops the end event under load; re-send like MMF does.
        let k = kind, o = originOffset, ld = lastDelta
        for delay in [0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !active else { return }
                postDock(phase: ph, kind: k, offset: o, last: ld)
            }
        }
    }

    private static func postDock(phase: ScrollPhase, kind k: SwipeKind? = nil, offset: Double? = nil, last: Double? = nil) {
        guard let hidCreate, let hidSetInt, let hidSetFloat, let setHID else { return }
        let bits: UInt32
        switch phase {
        case .began: bits = 1
        case .changed: bits = 2
        case .ended: bits = 4
        case .cancelled: bits = 8
        default: return
        }
        guard let ev = hidCreate(kCFAllocatorDefault, typeDockSwipe, 0, bits << phaseShift)?.takeRetainedValue() else { return }
        var progress = offset ?? originOffset
        if natural { progress = -progress } // macOS 27 applies the natural flip itself
        hidSetInt(ev, field(typeDockSwipe, 1), (k ?? kind).rawValue) // motion
        hidSetInt(ev, field(typeDockSwipe, 5), 3)                    // flavor: dock primary
        hidSetFloat(ev, field(typeDockSwipe, 2), progress)           // progress
        if bits == 4 || bits == 8, let hidAppend,
           let vel = hidCreate(kCFAllocatorDefault, typeVelocity, 0, 0)?.takeRetainedValue() {
            let exit = (last ?? lastDelta) * 100
            hidSetFloat(vel, field(typeVelocity, 0), exit)
            hidSetFloat(vel, field(typeVelocity, 1), exit)
            hidSetFloat(vel, field(typeVelocity, 2), 0)
            hidAppend(ev, vel, 0)
        }
        guard let e = CGEvent(source: nil) else { return }
        e.type = CGEventType(rawValue: 30)!
        e.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        setHID(e, ev)
        e.post(tap: .cgSessionEventTap)
    }

    /// Number of Spaces on the main display (for 1:1 horizontal swipes).
    static var spaceCount: Int {
        typealias Conn = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let c = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopyManagedDisplaySpaces") else { return 2 }
        let conn = unsafeBitCast(c, to: Conn.self)()
        guard let arr = unsafeBitCast(f, to: Copy.self)(conn)?.takeRetainedValue() as? [[String: Any]],
              let first = arr.first, let spaces = first["Spaces"] as? [Any] else { return 2 }
        return max(spaces.count, 1)
    }

    // MARK: one-shot actions

    static func run(_ action: ButtonAction) {
        switch action {
        case .none: break
        case .missionControl: dock("com.apple.expose.awake")
        case .appExpose: dock("com.apple.expose.front.awake")
        case .showDesktop: dock("com.apple.showdesktop.awake")
        case .launchpad: dock("com.apple.launchpad.toggle")
        case .back: universalNavigate(back: true)
        case .forward: universalNavigate(back: false)
        case .smartZoom: Synth.smartZoom()
        case .middleClick:
            Synth.middleClick(down: true); Synth.middleClick(down: false)
        case .shortcut(let s): Synth.key(s.keyCode, flags: s.modifiers)
        }
    }

    private static func dock(_ name: String) { dockNotify?(name as CFString, 0) }

    /// Back/Forward the way each app understands it (same routing idea as MMF's Universal Back).
    static func universalNavigate(back: Bool) {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let cmd: UInt64 = 1 << 20, opt: UInt64 = 1 << 19
        let bracket: UInt16 = back ? 33 : 30, arrow: UInt16 = back ? 123 : 124
        let cmdBracketApps = ["org.zotero.zotero", "com.apple.systempreferences", "com.apple.AppStore", "dev.warp.Warp",
                              "com.apple.Music", "com.apple.AddressBook", "com.apple.TV", "com.apple.iBooksX", "com.apple.Preview"]
        if cmdBracketApps.contains(where: { id.hasPrefix($0) }) {
            Synth.key(bracket, flags: cmd)
        } else if id.hasPrefix("com.adobe.Acrobat") || id.hasPrefix("com.apple.iCal") {
            Synth.key(arrow, flags: cmd)
        } else if id.hasPrefix("com.apple.Notes") || id.hasPrefix("com.apple.freeform") {
            Synth.key(bracket, flags: cmd | opt)
        } else if id.hasPrefix("com.apple.") || id.hasPrefix("com.operasoftware") || id.hasPrefix("com.binarynights.ForkLift") {
            Synth.navigationSwipe(back: back)
        } else {
            // Most non-Apple apps (Chromium, Electron, VS Code) understand mouse buttons 4/5.
            let n: Int64 = back ? 3 : 4
            Synth.repostButton(n, down: true); Synth.repostButton(n, down: false)
        }
    }
}
