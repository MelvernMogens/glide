import Foundation

// MARK: - Modifier mapping

/// Modifier keys held during a wheel tick, independent of CoreGraphics.
public struct HeldModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = HeldModifiers(rawValue: 1)
    public static let option = HeldModifiers(rawValue: 2)
    public static let shift = HeldModifiers(rawValue: 4)
    public static let control = HeldModifiers(rawValue: 8)

    /// From CGEventFlags raw bits.
    public init(cgFlags: UInt64) {
        var m: HeldModifiers = []
        if cgFlags & (1 << 20) != 0 { m.insert(.command) }
        if cgFlags & (1 << 19) != 0 { m.insert(.option) }
        if cgFlags & (1 << 17) != 0 { m.insert(.shift) }
        if cgFlags & (1 << 18) != 0 { m.insert(.control) }
        self = m
    }
}

public enum SpeedMode: Sendable, Equatable { case normal, precise, swift }

/// What one wheel tick should do once the held modifiers are applied.
public struct ScrollMode: Sendable, Equatable {
    public var zoom = false
    public var horizontal = false
    public var speed: SpeedMode = .normal
    /// CGEventFlags bits to strip from emitted events (modifiers Glide consumed).
    public var consumedFlags: UInt64 = 0
    public init(zoom: Bool = false, horizontal: Bool = false, speed: SpeedMode = .normal, consumedFlags: UInt64 = 0) {
        self.zoom = zoom; self.horizontal = horizontal; self.speed = speed; self.consumedFlags = consumedFlags
    }
}

extension ScrollModifiers {
    /// Combines held modifiers into one mode. Zoom wins over everything; horizontal combines with
    /// precise or swift (⌥⇧ = precise horizontal). Precise beats swift if both are held.
    public func mode(for held: HeldModifiers) -> ScrollMode {
        // No arrays here: this runs inside the event-tap callback and must not allocate.
        var m = ScrollMode()
        var precise = false, swift = false
        @inline(__always) func apply(_ key: HeldModifiers, _ action: ScrollModifierAction, _ bit: UInt64) {
            guard held.contains(key) else { return }
            switch action {
            case .none: return
            case .zoom: m.zoom = true
            case .horizontal: m.horizontal = true
            case .precise: precise = true
            case .swift: swift = true
            }
            m.consumedFlags |= bit
        }
        apply(.command, command, 1 << 20)
        apply(.option, option, 1 << 19)
        apply(.shift, shift, 1 << 17)
        apply(.control, control, 1 << 18)
        m.speed = precise ? .precise : (swift ? .swift : .normal)
        if m.zoom { m.horizontal = false; m.speed = .normal }
        return m
    }
}

// MARK: - Profiles

/// Fast-scroll ramp for consecutive swipes: f(x) = 1 for x < t, else a·1.1^((x−t)·c) + 1 − a,
/// a = (p−1)/(1.1^c − 1). Same shape and numbers as Mac Mouse Fix.
public struct SpeedupRamp: Equatable, Sendable {
    public var t: Double, p: Double, c: Double
    public func factor(swipes x: Double) -> Double {
        guard x.isFinite, x >= t else { return 1 }
        let a = (p - 1) / (pow(1.1, c) - 1)
        let f = a * pow(1.1, (x - t) * c) + 1 - a
        return f.isFinite ? min(max(f, 1), 50) : 50 // overflow only happens for huge x: cap
    }
}

/// Tunables for one smoothness/speed/modifier combination. Distances in points (px at 1x).
/// Numbers follow Mac Mouse Fix 3.1's ScrollConfig (see docs/prd.md §Feel parity).
public struct ScrollProfile: Equatable, Sendable {
    /// Points for one tick at slow spin (≤ 6.25 ticks/s) and at fast spin (≥ 66.7 ticks/s).
    public var minPx: Double
    public var maxPx: Double
    public var accelerate = true
    /// Base-curve length. With `minDuration` set, faster ticks shorten it (MMF "Regular").
    public var baseDuration: Double
    public var minDuration: Double? = nil
    /// Base curve shape: start slope and exit slope relative to a linear move (1/1 = linear).
    public var startSlope = 1.0
    public var exitSlope = 1.0
    /// Drag tail: v' = −a·v^b until v < stopSpeed (px/s). a = 0 disables the tail.
    public var dragCoef: Double
    public var dragExp: Double
    public var stopSpeed: Double
    public var speedup: SpeedupRamp?
    /// Ticks further apart than this end a swipe; swipes further apart than `swipeMaxInterval` reset the ramp.
    public var tickGap = 0.160
    public var swipeMaxInterval: Double

    public var smooth: Bool { baseDuration > 0 }

    /// Base duration for a tick arriving `interval` s after the previous one. Constant unless
    /// `minDuration` is set: then 160 ms → base, 1 ms → min, on an exponential curve.
    public func duration(tickInterval interval: Double) -> Double {
        guard let minD = minDuration else { return baseDuration }
        guard interval.isFinite else { return baseDuration }
        let x = min(max((0.160 - interval) / (0.160 - 0.001), 0), 1)
        let e = (exp(4 * x) - 1) / (exp(4) - 1)
        return baseDuration + (minD - baseDuration) * e
    }

    public static func make(smoothness: Smoothness, speed: ScrollSpeed, mode: SpeedMode, screenHeight: Double = 900) -> ScrollProfile {
        func pick(_ l: Double, _ m: Double, _ h: Double) -> Double {
            switch speed { case .slow: return l; case .medium: return m; case .fast: return h }
        }
        var p: ScrollProfile
        switch smoothness {
        case .off:
            p = .init(minPx: pick(20, 30, 40), maxPx: pick(40, 60, 80), baseDuration: 0,
                      dragCoef: 0, dragExp: 1, stopSpeed: 30, speedup: .init(t: 6, p: 1.4, c: 3), swipeMaxInterval: 0.325)
        case .low: // MMF "Regular": short linear push, faster ticks animate quicker, light inertia.
            p = .init(minPx: pick(30, 60, 120), maxPx: pick(90, 120, 180), baseDuration: 0.18, minDuration: 0.11,
                      dragCoef: 23, dragExp: 1.0, stopSpeed: 30, speedup: .init(t: 3, p: 1.33, c: 7.5), swipeMaxInterval: 0.375)
        case .medium: // between Regular and High
            p = .init(minPx: pick(45, 75, 135), maxPx: pick(105, 150, 210), baseDuration: 0.2,
                      startSlope: 1.8, exitSlope: 0.8,
                      dragCoef: 32, dragExp: 0.85, stopSpeed: 30, speedup: .init(t: 2, p: 1.33, c: 7.5), swipeMaxInterval: 0.5)
        case .high: // MMF "High": long inertial trackpad-like glide.
            p = .init(minPx: pick(60, 90, 150), maxPx: pick(120, 180, 240), baseDuration: 0.22,
                      startSlope: 2.4, exitSlope: 0.6,
                      dragCoef: 40, dragExp: 0.7, stopSpeed: 30, speedup: .init(t: 2, p: 1.33, c: 7.5), swipeMaxInterval: 0.6)
        }
        switch mode {
        case .normal: break
        case .precise: // slow, line-by-line, no ramp
            p.minPx = 10; p.maxPx = 20; p.speedup = nil
            if p.smooth {
                p.baseDuration = 0.14; p.minDuration = nil; p.startSlope = 1; p.exitSlope = 1
                p.dragCoef = 15; p.dragExp = 1.05; p.stopSpeed = 50
            }
        case .swift: // long distances relative to the screen
            let window = max(screenHeight.isFinite ? screenHeight : 900, 300) * 0.85
            p.minPx = 0.5 * window; p.maxPx = 1.5 * window
            p.speedup = .init(t: 1, p: 2.0, c: 10)
            p.tickGap = 0.2; p.swipeMaxInterval = 0.725
            if p.smooth {
                p.baseDuration = 0.3; p.minDuration = nil; p.startSlope = 1; p.exitSlope = 1
                p.dragCoef = 30; p.dragExp = 0.7; p.stopSpeed = 1
            }
        }
        return p
    }

    /// Zoom driver (pinch): magnification per tick, eased over 250 ms.
    public static func zoom(speed: ScrollSpeed) -> ScrollProfile {
        let minPx: Double, maxPx: Double
        switch speed { case .slow: (minPx, maxPx) = (45, 90); case .medium: (minPx, maxPx) = (60, 120); case .fast: (minPx, maxPx) = (90, 180) }
        return .init(minPx: minPx / 800, maxPx: maxPx / 800, baseDuration: 0.25, startSlope: 2.4, exitSlope: 0,
                     dragCoef: 0, dragExp: 1, stopSpeed: 0, speedup: .init(t: 3, p: 1.33, c: 7.5), swipeMaxInterval: 0.375)
    }
}

// MARK: - Tick analysis / acceleration

/// Turns discrete wheel ticks into distances: px per tick grows with spin speed (ticks/s), and
/// consecutive swipes in the same direction ramp up further. A pause or direction change resets.
public struct TickAccelerator: Sendable {
    public static let rateMin = 1 / 0.160   // ≤ this many ticks/s → minPx
    public static let rateMax = 1 / 0.015   // ≥ this → maxPx (linear beyond, capped)

    public private(set) var ticksInSwipe = 0
    /// Interval to the previous tick (∞ for the first one).
    public private(set) var lastInterval = Double.infinity
    public private(set) var consecutiveSwipes = 0
    private var lastTime = -Double.infinity
    private var lastDirection = 0
    private var intervals = (0.16, 0.16, 0.16)
    private var swipeStart = -Double.infinity

    public init() {}

    /// - Returns: signed distance for this tick.
    public mutating func distance(direction: Int, at time: Double, profile p: ScrollProfile) -> Double {
        let dir = direction >= 0 ? 1 : -1
        let dt = time - lastTime
        let valid = dt.isFinite && dt >= 0
        lastInterval = valid ? dt : .infinity
        let sameDir = dir == lastDirection
        if valid && sameDir && dt < p.tickGap {
            ticksInSwipe += 1
            let d = max(dt, 0.001)
            intervals = (intervals.1, intervals.2, d)
        } else {
            // New swipe: does it continue a run of swipes?
            if valid && sameDir && dt < p.swipeMaxInterval && ticksInSwipe >= 1 {
                consecutiveSwipes += 1
            } else {
                consecutiveSwipes = 0
            }
            ticksInSwipe = 0
            intervals = (0.16, 0.16, 0.16)
            swipeStart = time
        }
        lastTime = time
        lastDirection = dir
        return Double(dir) * pixels(profile: p)
    }

    /// Ticks per second over the last three intervals of this swipe.
    public var tickRate: Double {
        guard ticksInSwipe > 0 else { return Self.rateMin }
        let n = min(ticksInSwipe, 3)
        let sum: Double
        switch n {
        case 1: sum = intervals.2
        case 2: sum = intervals.1 + intervals.2
        default: sum = intervals.0 + intervals.1 + intervals.2
        }
        return Double(n) / max(sum, 0.001)
    }

    func pixels(profile p: ScrollProfile) -> Double {
        var px = p.minPx
        if p.accelerate {
            let x = (tickRate - Self.rateMin) / (Self.rateMax - Self.rateMin)
            px = p.minPx + (p.maxPx - p.minPx) * max(0, min(x, 2))
        }
        if let ramp = p.speedup { px *= ramp.factor(swipes: Double(consecutiveSwipes + 1)) }
        return px.isFinite ? px : p.minPx
    }

    public mutating func reset() {
        ticksInSwipe = 0; consecutiveSwipes = 0; lastTime = -.infinity; lastDirection = 0
        intervals = (0.16, 0.16, 0.16)
    }
}

// MARK: - Curves

public enum Easing {
    /// Cubic ease-out, clamped to [0, 1]. NaN in → 1 (finish), so a bad clock never stalls a scroll.
    @inline(__always)
    public static func easeOut(_ x: Double) -> Double { hermite(x, s0: 3, s1: 0) }

    /// Cubic Hermite from (0,0) to (1,1) with start slope s0 and end slope s1, clamped to [0,1].
    /// Monotone for s0, s1 ∈ [0, 3] with s0 + s1 ≤ 3 + small margin.
    @inline(__always)
    public static func hermite(_ x: Double, s0: Double, s1: Double) -> Double {
        guard x.isFinite else { return x.isNaN || x > 0 ? 1 : 0 }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let a = s0 + s1 - 2, b = 3 - 2 * s0 - s1
        let v = ((a * x + b) * x + s0) * x
        return min(max(v, 0), 1)
    }

    @inline(__always)
    public static func hermiteSlope(_ x: Double, s0: Double, s1: Double) -> Double {
        guard x.isFinite else { return 0 }
        let xc = min(max(x, 0), 1)
        let a = s0 + s1 - 2, b = 3 - 2 * s0 - s1
        return (3 * a * xc + 2 * b) * xc + s0
    }
}

/// Exponent-drag deceleration v' = −a·v^b (closed form), used for the inertia tail.
public struct DragTail: Equatable, Sendable {
    public var v0: Double, a: Double, b: Double, stop: Double

    public var isEmpty: Bool { !(a > 0) || !(v0 > stop) || !v0.isFinite }

    /// Distance covered from v0 down to the stop speed.
    public var distance: Double { isEmpty ? 0 : covered(atSpeed: stop) }

    public var duration: Double {
        guard !isEmpty else { return 0 }
        if abs(b - 1) < 1e-9 { return log(v0 / stop) / a }
        return (pow(v0, 1 - b) - pow(stop, 1 - b)) / (a * (1 - b))
    }

    public func speed(at t: Double) -> Double {
        guard !isEmpty, t.isFinite else { return 0 }
        if t <= 0 { return v0 }
        if abs(b - 1) < 1e-9 { return v0 * exp(-a * t) }
        let base = pow(v0, 1 - b) - a * (1 - b) * t
        if b < 1 { return base > 0 ? pow(base, 1 / (1 - b)) : 0 }
        return pow(base, 1 / (1 - b))
    }

    /// Distance covered once the speed has dropped to v.
    func covered(atSpeed v: Double) -> Double {
        if abs(b - 2) < 1e-9 { return log(v0 / max(v, 1e-9)) / a }
        return (pow(v0, 2 - b) - pow(max(v, 0), 2 - b)) / (a * (2 - b))
    }

    public func position(at t: Double) -> Double {
        guard !isEmpty else { return 0 }
        if t >= duration { return distance }
        return min(covered(atSpeed: speed(at: t)), distance)
    }
}

/// One planned scroll move: a base curve that hands off, at matching speed, to a drag tail.
/// Total distance is exact by construction (base distance solved by bisection).
public struct HybridCurve: Equatable, Sendable {
    public let total: Double        // signed
    public let baseDistance: Double // unsigned
    public let baseDuration: Double
    public let s0: Double, s1: Double
    public let tail: DragTail

    public init(distance: Double, duration: Double, profile p: ScrollProfile) {
        total = distance.isFinite ? distance : 0
        baseDuration = max(duration.isFinite ? duration : 0.001, 0.001)
        s0 = p.startSlope; s1 = p.exitSlope
        let D = abs(total)
        let T = baseDuration, k = s1
        func tail(for db: Double) -> DragTail { DragTail(v0: k * db / T, a: p.dragCoef, b: p.dragExp, stop: p.stopSpeed) }
        var lo = 0.0, hi = D
        if tail(for: D).isEmpty || D == 0 {
            lo = D
        } else {
            for _ in 0..<48 {
                let mid = (lo + hi) / 2
                if mid + tail(for: mid).distance > D { hi = mid } else { lo = mid }
            }
        }
        baseDistance = lo
        let t = tail(for: lo)
        // Snap: whatever bisection left over goes into the base so the sum is exact.
        tailDistance = t.isEmpty ? 0 : D - lo
        self.tail = t
    }

    public let tailDistance: Double

    public var duration: Double { baseDuration + (tail.isEmpty ? 0 : tail.duration) }

    /// Signed position at time t since start.
    public func position(at t: Double) -> Double {
        let sign: Double = total < 0 ? -1 : 1
        guard t.isFinite else { return total }
        if t >= duration { return total }
        if t <= baseDuration {
            return sign * baseDistance * Easing.hermite(t / baseDuration, s0: s0, s1: s1)
        }
        let tp = tail.position(at: t - baseDuration)
        let scaled = tail.distance > 0 ? tp / tail.distance * tailDistance : 0
        return sign * (baseDistance + min(scaled, tailDistance))
    }

    /// Signed speed (px/s) at time t.
    public func velocity(at t: Double) -> Double {
        let sign: Double = total < 0 ? -1 : 1
        guard t.isFinite, t >= 0, t < duration else { return 0 }
        if t <= baseDuration { return sign * baseDistance / baseDuration * Easing.hermiteSlope(t / baseDuration, s0: s0, s1: s1) }
        return sign * tail.speed(at: t - baseDuration)
    }

    public func inTail(at t: Double) -> Bool { !tail.isEmpty && t > baseDuration }
}
