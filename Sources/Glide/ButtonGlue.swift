import AppKit
import GlideKit

/// Glue between the event tap and the pure ButtonEngine. The tap callback only decides
/// "is this button ours?" (a precomputed bitmask), records the input in a fixed buffer and
/// swallows it; the engine-thread kick feeds ButtonEngine and runs the resulting actions.
final class ButtonGlue {
    unowned let engine: Engine
    private var machine = ButtonEngine(configs: [:])
    private var interceptMask: UInt8 = 0          // bit n = MouseButton rawValue n
    private var scrollButtonRaw = 0               // 0 = no hold+scroll gesture
    private var heldScrollButton = 0              // set in the callback while that button is down
    private var dragMask: UInt8 = 0               // buttons whose drags Glide needs
    private var passedDownRaw = 0                 // button currently re-posted as a plain press
    private var needsReset = false                // set by the callback when the tap was disabled
    private var cachedSpaces = 2
    private var cachedScreen = CGSize(width: 1440, height: 900)

    // fixed input ring (callback -> kick)
    private struct Pending { var kind: UInt8 = 0; var button = 0; var dx = 0.0; var dy = 0.0; var t = 0.0 }
    private var pending = [Pending](repeating: Pending(), count: 128)
    private var pendingCount = 0

    // drag gesture state (kick only)
    private enum Axis { case none, horizontal, vertical }
    private var dragAxis = Axis.none
    private var dragging = false
    private var scrollGestureActive = false
    private var scrollGestureMode = ScrollGestureMode.zoom
    private var timer: CFRunLoopTimer?

    init(engine: Engine) {
        self.engine = engine
        settingsChanged()
    }

    /// Engine thread.
    func settingsChanged() {
        let s = engine.settings
        let configs = s.enabled ? s.buttonConfigs : [:]
        scrollGestureMode = s.scrollGestureMode
        // Only rebuild when the button setup really changed, and close whatever was in flight.
        guard configs != machine.configs else { return }
        resetAll()
        machine = ButtonEngine(configs: configs, doubleClickWindow: min(NSEvent.doubleClickInterval, 0.4))
        var mask: UInt8 = 0, dmask: UInt8 = 0
        for (b, c) in configs { mask |= 1 << UInt8(b.rawValue); if c.drag { dmask |= 1 << UInt8(b.rawValue) } }
        interceptMask = mask
        dragMask = dmask
        scrollButtonRaw = s.enabled ? (s.scrollGestureButton?.rawValue ?? 0) : 0
        heldScrollButton = 0
    }

    /// Engine thread: end any gesture / held press cleanly (settings change, quit, tap disabled).
    func resetAll() {
        for o in machine.reset() { run(o) }
        if dragging, dragAxis != .none { Gestures.endDockSwipe() }
        if scrollGestureActive, scrollGestureMode != .zoom { Gestures.endDockSwipe() }
        dragging = false; dragAxis = .none; scrollGestureActive = false; scrollGestureBegun = false
        if passedDownRaw != 0 { passedDownRaw = 0 }
        heldScrollButton = 0
        pendingCount = 0
    }

    /// Callback side: a disabled tap may have missed button releases. Forget held state now,
    /// finish the cleanup on the kick.
    @inline(__always) func tapWasDisabled() {
        heldScrollButton = 0
        needsReset = true
        engine.signalKick()
    }

    // MARK: callback side (no allocation)

    /// Returns true if consumed.
    @inline(__always)
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard interceptMask != 0 else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == kGlideMark { return false }
        let raw = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
        guard raw >= 3, raw <= 5, interceptMask & (1 << UInt8(raw)) != 0, pendingCount < pending.count else { return false }
        let kind: UInt8
        switch type {
        case .otherMouseDown: kind = 0; if raw == scrollButtonRaw { heldScrollButton = raw }
        case .otherMouseUp: kind = 1; if raw == heldScrollButton { heldScrollButton = 0 }
        default:
            // Drags only matter for drag gestures; a plain re-posted press must keep dragging in apps.
            if dragMask & (1 << UInt8(raw)) == 0 || raw == passedDownRaw { return false }
            kind = 2
        }
        pending[pendingCount] = Pending(kind: kind, button: raw,
                                        dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                                        dy: Double(event.getIntegerValueField(.mouseEventDeltaY)), t: uptime())
        pendingCount += 1
        engine.signalKick()
        return true
    }

    /// A wheel tick while the hold+scroll button is down. Returns true if consumed.
    @inline(__always)
    func scrollWhileHeld(_ e: CGEvent, delta: Int64) -> Bool {
        guard heldScrollButton != 0, pendingCount < pending.count else { return false }
        var d = Double(delta.signum())
        if engine.invertDirection { d = -d }
        pending[pendingCount] = Pending(kind: 3, button: heldScrollButton, dx: 0, dy: d, t: uptime())
        pendingCount += 1
        engine.signalKick()
        return true
    }

    // MARK: kick side (engine thread, after the callback returned)

    func drain() {
        if needsReset { needsReset = false; resetAll() }
        let n = pendingCount
        guard n > 0 else { return }
        for i in 0..<n {
            let p = pending[i]
            guard let b = MouseButton(rawValue: p.button) else { continue }
            let input: ButtonInput
            switch p.kind {
            case 0: input = .down(b, t: p.t)
            case 1: input = .up(b, t: p.t)
            case 2: input = .drag(b, dx: p.dx, dy: p.dy, t: p.t)
            default: input = .scroll(b, t: p.t)
            }
            for o in machine.handle(input) { run(o) }
            if p.kind == 2, dragging { dragMoved(dx: p.dx, dy: p.dy) }
            if p.kind == 3 {
                if scrollGestureActive { scrollTick(direction: p.dy, t: p.t) }
                else { engine.fallbackScrollTick(direction: Int(p.dy), at: p.t) } // never drop a tick
            }
        }
        pendingCount = 0
        armTimer()
    }

    private func run(_ o: ButtonOutput) {
        switch o {
        case .passClick(let b):
            Synth.repostButton(b.cgButtonNumber, down: true); Synth.repostButton(b.cgButtonNumber, down: false)
        case .passDown(let b): passedDownRaw = b.rawValue; Synth.repostButton(b.cgButtonNumber, down: true)
        case .passUp(let b): passedDownRaw = 0; Synth.repostButton(b.cgButtonNumber, down: false)
        case .action(let a): Gestures.run(a)
        case .dragBegan:
            dragging = true; dragAxis = .none
            cachedSpaces = Gestures.spaceCount
            cachedScreen = engine.screenSize
        case .dragMoved: break // handled with the raw deltas in drain()
        case .dragEnded:
            if dragging, dragAxis != .none { Gestures.endDockSwipe() }
            dragging = false; dragAxis = .none
        case .scrollGestureBegan: scrollGestureActive = true
        case .scrollGestureEnded:
            if scrollGestureMode != .zoom { Gestures.endDockSwipe() }
            scrollGestureActive = false
            scrollGestureBegun = false
        }
    }

    /// Three-finger-swipe emulation: follows the pointer 1:1 (MMF's scaling).
    private func dragMoved(dx rawX: Double, dy rawY: Double) {
        var dx = rawX, dy = rawY
        if !Gestures.natural { dx = -dx; dy = -dy }
        let first = dragAxis == .none
        if first {
            guard dx != 0 || dy != 0 else { return }
            dragAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        let screen = cachedScreen
        let delta: Double
        if dragAxis == .horizontal {
            let n = cachedSpaces
            let perSpace = n <= 1 ? 2.0 : 1 + 1 / Double(n - 1)
            delta = -dx * perSpace / (screen.width + 63)
        } else {
            delta = dy / screen.height
        }
        Gestures.dockSwipe(dragAxis == .horizontal ? .horizontal : .vertical, delta: delta, phase: first ? .began : .changed)
    }

    private var lastScrollGestureTime = -Double.infinity
    private var scrollGestureBegun = false

    private func scrollTick(direction: Double, t: Double) {
        switch scrollGestureMode {
        case .zoom:
            engine.addZoomTick(direction: Int(direction), at: t)
        case .desktopLaunchpad, .spaces:
            let kind: Gestures.SwipeKind = scrollGestureMode == .spaces ? .horizontal : .pinch
            let step = -direction * (scrollGestureMode == .spaces ? 0.35 : 0.15)
            // One gesture per hold; ends on release (dragEnded/scrollGestureEnded) so it snaps.
            let begin = !scrollGestureBegun || t - lastScrollGestureTime > 1.5
            Gestures.dockSwipe(kind, delta: step, phase: begin ? .began : .changed)
            scrollGestureBegun = true
            lastScrollGestureTime = t
        }
    }

    private func armTimer() {
        if timer == nil, let rl = engine.runLoop {
            var ctx = CFRunLoopTimerContext()
            ctx.info = Unmanaged.passUnretained(self).toOpaque()
            timer = CFRunLoopTimerCreate(nil, .greatestFiniteMagnitude, .greatestFiniteMagnitude, 0, 0, { _, info in
                let g = Unmanaged<ButtonGlue>.fromOpaque(info!).takeUnretainedValue()
                for o in g.machine.handle(.timer(t: uptime())) { g.run(o) }
                g.armTimer()
            }, &ctx)
            CFRunLoopAddTimer(rl, timer, .commonModes)
        }
        guard let timer else { return }
        if let d = machine.nextDeadline, d.isFinite {
            CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + max(0, d - uptime()) + 0.001)
        } else {
            CFRunLoopTimerSetNextFireDate(timer, .greatestFiniteMagnitude)
        }
    }
}
