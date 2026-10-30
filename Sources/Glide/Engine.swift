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
    var screenWidth = 1440.0
    var screenSize: CGSize { CGSize(width: screenWidth, height: screenHeight) }
    var qv = Quantizer(), qh = Quantizer()
    var invertDirection = false          // = settings.reverseDirection
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
    var pxPlanned = 0.0, pxOut = 0.0

    private(set) var isRunning = false
    var onTapStateChange: ((Bool) -> Void)?

    // MARK: start

    /// Starts the engine thread. Returns false if the tap could not be created (no Accessibility).
    func start(settings: GlideSettings) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let newLink = makeLink()
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
                self.install(newLink)
                // Fallback frame clock if there is no display link (no screen, lid closed).
                var tctx = CFRunLoopTimerContext()
                tctx.info = Unmanaged.passUnretained(self).toOpaque()
                self.fallbackTimer = CFRunLoopTimerCreate(nil, .greatestFiniteMagnitude, 1.0 / 60, 0, 0, { _, info in
                    Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue().frameTick()
                }, &tctx)
                CFRunLoopAddTimer(self.runLoop, self.fallbackTimer, .commonModes)
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

    private var fallbackTimer: CFRunLoopTimer?

    /// Main thread: build a display link for the main screen (nil if there is no screen).
    func makeLink() -> (CADisplayLink, Double, Double, Double)? {
        guard let screen = NSScreen.main else { return nil }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        let fps = Float(max(screen.maximumFramesPerSecond, 60))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        l.isPaused = true
        return (l, 1.0 / Double(fps), Double(screen.frame.height), Double(screen.frame.width))
    }

    /// Engine thread: swap in a new display link.
    private func install(_ new: (CADisplayLink, Double, Double, Double)?) {
        link?.invalidate()
        link = nil
        guard let (l, period, height, width) = new else { return }
        screenWidth = width
        l.add(to: .current, forMode: .common)
        link = l
        framePeriod = period
        screenHeight = height
    }

    /// Main thread, on screen configuration changes.
    func screensChanged() {
        let new = makeLink()
        perform { self.install(new); if self.animating { self.startFrames() } }
    }

    private var animating: Bool { vertical.isActive || horizontal.isActive || zoom.isActive }

    private func startFrames() {
        if let link { link.isPaused = false }
        else if let fallbackTimer { CFRunLoopTimerSetNextFireDate(fallbackTimer, CFAbsoluteTimeGetCurrent() + framePeriod) }
    }

    private func stopFrames() {
        link?.isPaused = true
        if let fallbackTimer { CFRunLoopTimerSetNextFireDate(fallbackTimer, .greatestFiniteMagnitude) }
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
        // Same meaning as Mac Mouse Fix: "Reverse direction" flips the system scroll direction for
        // the mouse only. With macOS Natural scrolling on (trackpad natural), the mouse becomes
        // traditional: wheel down = page down. The trackpad never passes through this code.
        invertDirection = settings.reverseDirection
        trackpadSim = settings.trackpadSimulation
        Synth.invertedFromDevice = 1 // MMF always sets this
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
        buttons?.tapWasDisabled()
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
            if mode.horizontal && d2 == 0 { swapToHorizontal(e, clearing: mode.consumedFlags) }
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
        startFrames()
    }

    private func negateDiscrete(_ e: CGEvent) {
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -e.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -e.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        e.setIntegerValueField(Synth.fInvertedFromDevice, value: Synth.invertedFromDevice)
    }

    private func swapToHorizontal(_ e: CGEvent, clearing: UInt64) {
        let d = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let p = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let f = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: d)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: p)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: f)
        e.flags = CGEventFlags(rawValue: e.flags.rawValue & ~clearing)
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
                pxPlanned += abs(d)
                if pendingHorizontal[i] {
                    if vertical.isActive { flush(&vertical, vertical: true) }
                    horizontal.addTick(d, at: t, duration: dur, profile: p)
                } else {
                    if horizontal.isActive { flush(&horizontal, vertical: false) }
                    vertical.addTick(d, at: t, duration: dur, profile: p)
                }
            }
        }
        pendingCount = 0
        advance()
        startFrames()
    }

    @objc private func frame(_ l: CADisplayLink) { frameTick() }

    private func frameTick() {
        advance()
        if !animating { stopFrames() }
    }

    /// A wheel tick that arrived while a gesture button was held but didn't become a gesture:
    /// scroll it normally instead of dropping it.
    func fallbackScrollTick(direction: Int, at t: Double) {
        let p = ScrollProfile.make(smoothness: settings.smoothness == .off ? .low : settings.smoothness,
                                   speed: settings.speed, mode: .normal, screenHeight: screenHeight)
        let d = accel.distance(direction: direction, at: t, profile: p)
        if horizontal.isActive { flush(&horizontal, vertical: false) }
        vertical.addTick(d, at: t, duration: p.duration(tickInterval: accel.lastInterval), profile: p)
        advance()
        startFrames()
    }

    /// Close one axis immediately (only one 2-D gesture may be open at a time, like a trackpad).
    private func flush(_ a: inout ScrollAnimator, vertical v: Bool) {
        let out = a.cancel()
        for i in 0..<out.count { _ = postScroll(out[i], vertical: v) }
        if v { qv.reset(); vBeganPending = false } else { qh.reset(); hBeganPending = false }
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

    private var vBeganPending = false, hBeganPending = false

    /// Returns true if an event carrying motion was posted.
    private func postScroll(_ e: ScrollEmit, vertical: Bool) -> Bool {
        let px = vertical ? qv.take(e.delta) : qh.take(e.delta)
        var phase = e.phase
        // Trackpads never send Began/MomentumBegan with zero delta: hold the "began" back until
        // the first frame that actually moves.
        if px == 0 && (phase == .began || phase == .changed) {
            if phase == .began { if vertical { vBeganPending = true } else { hBeganPending = true } }
            return false
        }
        if px == 0 && phase == .momentumChanged { return false }
        if phase == .changed, vertical ? vBeganPending : hBeganPending {
            phase = .began
            if vertical { vBeganPending = false } else { hBeganPending = false }
        }
        if phase == .ended, vertical ? vBeganPending : hBeganPending {
            // Gesture never moved a pixel: nothing was begun, so nothing to end.
            if vertical { vBeganPending = false } else { hBeganPending = false }
            return false
        }
        if !trackpadSim && (phase == .ended || phase == .momentumEnded || phase == .mayBegin || phase == .cancelled || px == 0) { return false }
        Synth.scroll(dy: vertical ? px : 0, dx: vertical ? 0 : px, phase: trackpadSim ? phase : nil, flags: emitFlags)
        eventsOut += 1
        pxOut += Double(abs(px))
        // Drop the sub-pixel remainder only once the whole move (incl. momentum) is over.
        if phase == .cancelled { if vertical { qv.reset() } else { qh.reset() } }
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
        qv.reset(); qh.reset(); vBeganPending = false; hBeganPending = false
        buttons?.resetAll()
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
