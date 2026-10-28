import AppKit
import ApplicationServices
import QuartzCore
import GlideKit

/// Marks every event Glide posts so the tap never re-processes its own output.
let kGlideMark: Int64 = 0x474C_4944_45 // "GLIDE"

@inline(__always) func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 }

/// Latency samples (tap callback -> first event posted carrying that tick). Fixed buffer.
struct LatencyLog {
    static let capacity = 4096
    var samples = [Double](repeating: 0, count: capacity)
    var count = 0
    var pendingTickTime = -1.0
    mutating func add(_ s: Double) { if count < Self.capacity { samples[count] = s; count += 1 } }
}

/// Runs on one dedicated thread that owns everything: the event tap, a kick run-loop source and
/// the display link. The tap callback only records the tick and signals the kick source; the
/// kick (same thread, right after the callback returns) posts the first frame. No locks in the
/// event path, no allocation in the callback.
final class Engine: NSObject, @unchecked Sendable {
    static let shared = Engine()

    // ---- confined to engine thread ----
    private(set) var settings = GlideSettings()
    private var tap: CFMachPort?
    private var kickSource: CFRunLoopSource?
    private(set) var runLoop: CFRunLoop?
    private var link: CADisplayLink?
    private var framePeriod = 1.0 / 60

    var vertical = ScrollAnimator()
    var horizontal = ScrollAnimator()
    var zoom = ScrollAnimator()
    var accel = TickAccelerator()
    var zoomAccel = TickAccelerator()
    var screenHeight = 900.0
    var qv = Quantizer(), qh = Quantizer()
    var invertDirection = false          // computed from settings + system natural setting
    var smoothingOffForFrontApp = false
    var emitFlags: UInt64 = 0             // flags (minus consumed modifiers) for synthesized events
    var trackpadSim = true

    // pending ticks written by the callback, read by the kick (same thread)
    private var pendingCount = 0
    private var pendingDir = [Int](repeating: 0, count: 64)
    private var pendingHorizontal = [Bool](repeating: false, count: 64)
    private var pendingZoom = [Bool](repeating: false, count: 64)
    private var pendingTime = [Double](repeating: 0, count: 64)
    private var pendingProfile = [ScrollProfile](repeating: ScrollProfile.make(smoothness: .high, speed: .medium, mode: .normal), count: 64)

    var latency = LatencyLog()
    var buttons: ButtonGlue!

    // counters for --probe
    var ticksIn = 0, eventsOut = 0, passthrough = 0, tapReenables = 0

    private(set) var isRunning = false
    var onTapStateChange: ((Bool) -> Void)?

    // MARK: start

    /// Starts the engine thread. Returns false if the tap could not be created (no Accessibility).
    func start(settings: GlideSettings) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let screen = NSScreen.main
        let t = Thread { [self] in
            self.settings = settings
            self.applySettingsOnThread()
            ok = self.installTap()
            if ok {
                self.runLoop = CFRunLoopGetCurrent()
                var ctx = CFRunLoopSourceContext()
                ctx.info = Unmanaged.passUnretained(self).toOpaque()
                ctx.perform = { info in Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue().kick() }
                self.kickSource = CFRunLoopSourceCreate(nil, 0, &ctx)
                CFRunLoopAddSource(self.runLoop, self.kickSource, .commonModes)
                if let screen {
                    self.screenHeight = Double(screen.frame.height)
                    let l = screen.displayLink(target: self, selector: #selector(self.frame(_:)))
                    let fps = Float(max(screen.maximumFramesPerSecond, 60))
                    l.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
                    l.isPaused = true
                    l.add(to: .current, forMode: .common)
                    self.link = l
                    self.framePeriod = 1.0 / Double(fps)
                }
                self.buttons = ButtonGlue(engine: self)
            }
            ready.signal()
            if ok {
                self.isRunning = true
                CFRunLoopRun()
            }
        }
        t.name = "glide.engine"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        return ok
    }

    func update(settings: GlideSettings) {
        perform { self.settings = settings; self.applySettingsOnThread() }
    }

    func setFrontAppSmoothingOff(_ off: Bool) { perform { self.smoothingOffForFrontApp = off } }

    func refreshSystemDirection() { perform { self.applySettingsOnThread() } }

    /// Runs `block` on the engine thread.
    func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { block(); return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func applySettingsOnThread() {
        let systemNatural = (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
        // Real wheel events already arrive flipped when the system setting is natural.
        invertDirection = settings.reverseDirection != systemNatural
        trackpadSim = settings.trackpadSimulation
        if !settings.enabled { flushAll() }
        buttons?.settingsChanged()
    }

    // MARK: tap

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); tapReenables += 1 }
    }

    func reenableTapFromMain() { reenableTap() }

    var tapIsEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    // MARK: hot path (called from tapCallback)

    /// Returns true if the event was consumed.
    @inline(__always)
    fileprivate func handleScroll(_ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == kGlideMark { return false }
        guard settings.enabled else { return false }
        // Trackpad, Magic Mouse and other precise devices: never touch.
        if e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 { return false }
        let d1 = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let d2 = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if d1 == 0 && d2 == 0 { return false }

        if buttons.scrollWhileHeld(e, delta: d1 != 0 ? d1 : d2) { return true }

        let flags = e.flags.rawValue
        let mode = settings.modifiers.mode(for: HeldModifiers(cgFlags: flags))
        let smoothOff = settings.smoothness == .off || smoothingOffForFrontApp

        if smoothOff && !mode.zoom {
            // No smoothing: keep the discrete event, only fix direction / axis.
            passthrough += 1
            if invertDirection { negateDiscrete(e) }
            if mode.horizontal && d2 == 0 { swapToHorizontal(e) }
            return false
        }

        guard pendingCount < 64 else { return true } // flood: drop, never block
        var dir = Int(d1 != 0 ? d1.signum() : d2.signum())
        if invertDirection { dir = -dir }
        let i = pendingCount
        pendingDir[i] = dir
        pendingHorizontal[i] = mode.horizontal || d1 == 0
        pendingZoom[i] = mode.zoom
        pendingTime[i] = uptime()
        pendingProfile[i] = mode.zoom ? ScrollProfile.zoom(speed: settings.speed)
            : ScrollProfile.make(smoothness: settings.smoothness, speed: settings.speed, mode: mode.speed, screenHeight: screenHeight)
        pendingCount += 1
        emitFlags = flags & ~mode.consumedFlags
        ticksIn += 1
        signalKick()
        return true
    }

    @inline(__always) func signalKick() {
        if let kickSource, let runLoop { CFRunLoopSourceSignal(kickSource); CFRunLoopWakeUp(runLoop) }
    }

    /// Hold-button + scroll zoom (engine thread).
    func addZoomTick(direction: Int, at t: Double) {
        let p = ScrollProfile.zoom(speed: settings.speed)
        zoom.addTick(zoomAccel.distance(direction: direction, at: t, profile: p), at: t, duration: p.baseDuration, profile: p)
        if latency.pendingTickTime < 0 { latency.pendingTickTime = t }
        advance()
        link?.isPaused = false
    }

    private func negateDiscrete(_ e: CGEvent) {
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -e.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -e.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
    }

    private func swapToHorizontal(_ e: CGEvent) {
        let d = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let p = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let f = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: d)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: p)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: f)
        e.flags = CGEventFlags(rawValue: e.flags.rawValue & ~(1 << 17))
    }

    // MARK: animation (engine thread, outside the callback)

    /// Kick: drain pending ticks and post the first frame right away.
    private func kick() {
        buttons?.drain()
        let n = pendingCount
        guard n > 0 else { return }
        for i in 0..<n {
            let p = pendingProfile[i]
            let t = pendingTime[i]
            if latency.pendingTickTime < 0 { latency.pendingTickTime = t }
            if pendingZoom[i] {
                let d = zoomAccel.distance(direction: pendingDir[i], at: t, profile: p)
                zoom.addTick(d, at: t, duration: p.baseDuration, profile: p)
            } else {
                let d = accel.distance(direction: pendingDir[i], at: t, profile: p)
                let dur = p.duration(tickInterval: accel.lastInterval)
                if pendingHorizontal[i] {
                    horizontal.addTick(d, at: t, duration: dur, profile: p)
                } else {
                    vertical.addTick(d, at: t, duration: dur, profile: p)
                }
            }
        }
        pendingCount = 0
        advance()
        link?.isPaused = false
    }

    @objc private func frame(_ l: CADisplayLink) {
        advance()
        if !vertical.isActive && !horizontal.isActive && !zoom.isActive { l.isPaused = true }
    }

    private func advance() {
        let now = uptime()
        let ov = vertical.step(to: now, lookahead: framePeriod)
        let oh = horizontal.step(to: now, lookahead: framePeriod)
        let oz = zoom.step(to: now, lookahead: framePeriod)
        var posted = false
        for i in 0..<ov.count { posted = postScroll(ov[i], vertical: true) || posted }
        for i in 0..<oh.count { posted = postScroll(oh[i], vertical: false) || posted }
        for i in 0..<oz.count { Synth.magnify(oz[i]); posted = true }
        if posted, latency.pendingTickTime >= 0 {
            latency.add(uptime() - latency.pendingTickTime)
            latency.pendingTickTime = -1
        }
    }

    /// Returns true if an event carrying motion was posted.
    private func postScroll(_ e: ScrollEmit, vertical: Bool) -> Bool {
        let px = vertical ? qv.take(e.delta) : qh.take(e.delta)
        if e.phase == .ended || e.phase == .momentumEnded {
            if vertical { qv.reset() } else { qh.reset() }
        }
        // Skip empty "changed" frames; phase boundaries are always posted.
        if px == 0 && (e.phase == .changed || e.phase == .momentumChanged) { return false }
        if !trackpadSim && (e.phase == .ended || e.phase == .momentumEnded || px == 0) { return false }
        Synth.scroll(dy: vertical ? px : 0, dx: vertical ? 0 : px, phase: trackpadSim ? e.phase : nil, flags: emitFlags)
        eventsOut += 1
        return px != 0
    }

    func flushAll() {
        for (out, v) in [(vertical.cancel(), true), (horizontal.cancel(), false)] {
            for i in 0..<out.count { _ = postScroll(out[i], vertical: v) }
        }
        let oz = zoom.cancel()
        for i in 0..<oz.count { Synth.magnify(oz[i]) }
        accel.reset()
        zoomAccel.reset()
    }

    func stop() {
        perform {
            self.flushAll()
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: false) }
            self.link?.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}

/// C callback. Never blocks, never allocates.
private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let engine = Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        engine.reenableTap()
        return Unmanaged.passUnretained(event)
    case .scrollWheel:
        return engine.handleScroll(event) ? nil : Unmanaged.passUnretained(event)
    case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
        return engine.buttons.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}
