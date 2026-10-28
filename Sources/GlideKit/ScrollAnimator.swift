import Foundation

/// Trackpad-style phase of one synthesized scroll event.
public enum ScrollPhase: UInt8, Sendable {
    case began, changed, ended, momentumBegan, momentumChanged, momentumEnded
    /// A zero-delta "touch then lift" pair posted after a scroll comes to rest. Real trackpads emit it
    /// for a tap; apps with their own inertia (Xcode, iPad apps) take it as "stop, no momentum".
    case mayBegin, cancelled
    public var isMomentum: Bool { self == .momentumBegan || self == .momentumChanged || self == .momentumEnded }
}

public struct ScrollEmit: Equatable, Sendable {
    public var delta: Double
    public var phase: ScrollPhase
    public init(_ delta: Double, _ phase: ScrollPhase) { self.delta = delta; self.phase = phase }
}

/// Fixed-size result of one animation step (no heap allocation).
public struct StepOutput: Sendable {
    public private(set) var count = 0
    public static let capacity = 6
    private var slots: (ScrollEmit, ScrollEmit, ScrollEmit, ScrollEmit, ScrollEmit, ScrollEmit) = (
        ScrollEmit(0, .changed), ScrollEmit(0, .changed), ScrollEmit(0, .changed),
        ScrollEmit(0, .changed), ScrollEmit(0, .changed), ScrollEmit(0, .changed))
    public init() {}
    mutating func append(_ e: ScrollEmit) {
        switch count {
        case 0: slots.0 = e
        case 1: slots.1 = e
        case 2: slots.2 = e
        case 3: slots.3 = e
        case 4: slots.4 = e
        case 5: slots.5 = e
        default: return
        }
        count += 1
    }
    mutating func appendRestTap() { append(ScrollEmit(0, .mayBegin)); append(ScrollEmit(0, .cancelled)) }
    public subscript(i: Int) -> ScrollEmit {
        switch i { case 0: return slots.0; case 1: return slots.1; case 2: return slots.2
        case 3: return slots.3; case 4: return slots.4; default: return slots.5 }
    }
    public var all: [ScrollEmit] { (0..<count).map { self[$0] } }
}

/// One scroll axis. Every tick plans a fresh HybridCurve (base push -> inertia tail) for its own
/// distance plus whatever the running move has not delivered yet, so distance is never lost or
/// duplicated. Phases follow a real trackpad: began/changed while the "fingers" push (the base
/// curve, and at least the first 160 ms), ended, momentum for the tail, then a rest tap.
public struct ScrollAnimator: Sendable {
    public enum State: Sendable, Equatable { case idle, gesture, momentum }
    public private(set) var state: State = .idle

    private var curve = HybridCurve(distance: 0, duration: 0.2, profile: .make(smoothness: .high, speed: .medium, mode: .normal))
    private var start = 0.0
    private var emitted = 0.0
    private var began = false, momentumBegun = false
    private var pendingMomentumEnd = false
    /// Minimum time a move stays in the gesture phase (apps like Xcode ignore pure momentum).
    public static let minGestureTime = 0.160

    public init() {}

    public var isActive: Bool { state != .idle || pendingMomentumEnd }

    /// Distance still to be delivered by the running move (signed).
    public var remaining: Double { state == .idle ? 0 : curve.total - emitted }

    /// - Parameter duration: base-curve length for this tick (`profile.duration(tickInterval:)`).
    public mutating func addTick(_ distance: Double, at t: Double, duration: Double, profile: ScrollProfile) {
        guard distance.isFinite, t.isFinite, distance != 0, duration.isFinite else { return }
        var carry = remaining
        if carry != 0, (carry > 0) != (distance > 0) { carry = 0 } // direction change: catch, go the other way
        switch state {
        case .idle: began = false
        case .gesture: break
        case .momentum:
            if momentumBegun { pendingMomentumEnd = true }
            began = false
        }
        state = .gesture
        curve = HybridCurve(distance: carry + distance, duration: duration, profile: profile)
        start = t
        emitted = 0
        momentumBegun = false
    }

    /// Advance to `t`. `lookahead` (one frame) makes the first event of a tick carry the first
    /// frame's motion immediately instead of a zero delta.
    public mutating func step(to t: Double, lookahead: Double = 0) -> StepOutput {
        var out = StepOutput()
        if pendingMomentumEnd { out.append(ScrollEmit(0, .momentumEnded)); pendingMomentumEnd = false }
        guard t.isFinite, state != .idle else { return out }
        var el = t + (lookahead.isFinite ? max(0, lookahead) : 0) - start
        if !el.isFinite { el = curve.duration }
        el = max(el, 0)
        let target = curve.position(at: el)
        let delta = target - emitted
        emitted = target
        let done = el >= curve.duration

        switch state {
        case .gesture where curve.inTail(at: el) && el >= Self.minGestureTime:
            // Hand-off: close the gesture, continue as momentum.
            if began {
                out.append(ScrollEmit(0, .ended))
                out.append(ScrollEmit(delta, .momentumBegan))
                momentumBegun = true
            } else {
                out.append(ScrollEmit(delta, .began))
                out.append(ScrollEmit(0, .ended))
                began = true
            }
            state = .momentum
        case .gesture:
            out.append(ScrollEmit(delta, began ? .changed : .began))
            began = true
        case .momentum:
            out.append(ScrollEmit(delta, momentumBegun ? .momentumChanged : .momentumBegan))
            momentumBegun = true
        case .idle:
            break
        }
        if done { finish(&out) }
        return out
    }

    private mutating func finish(_ out: inout StepOutput) {
        if state == .gesture {
            out.append(ScrollEmit(0, .ended))
        } else if momentumBegun {
            out.append(ScrollEmit(0, .momentumEnded))
        }
        out.appendRestTap()
        state = .idle
    }

    /// Stop immediately (e.g. Glide switched off). Returns the closing events to post.
    public mutating func cancel() -> StepOutput {
        var out = StepOutput()
        if pendingMomentumEnd { out.append(ScrollEmit(0, .momentumEnded)); pendingMomentumEnd = false }
        switch state {
        case .gesture: if began { out.append(ScrollEmit(0, .ended)) }
        case .momentum: if momentumBegun { out.append(ScrollEmit(0, .momentumEnded)) }
        case .idle: break
        }
        state = .idle
        return out
    }
}

/// Turns fractional point deltas into whole-pixel event deltas without drifting.
public struct Quantizer: Sendable {
    private var acc = 0.0
    public init() {}
    public mutating func take(_ d: Double) -> Int32 {
        guard d.isFinite else { return 0 }
        acc += d
        let whole = acc.rounded(.towardZero)
        acc -= whole
        return Int32(clamping: Int64(max(min(whole, 1e6), -1e6)))
    }
    public mutating func reset() { acc = 0 }
}
