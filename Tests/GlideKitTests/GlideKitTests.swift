import XCTest
@testable import GlideKit

final class EasingTests: XCTestCase {
    func testClampsAndEndpoints() {
        XCTAssertEqual(Easing.easeOut(0), 0)
        XCTAssertEqual(Easing.easeOut(1), 1)
        XCTAssertEqual(Easing.easeOut(-5), 0)
        XCTAssertEqual(Easing.easeOut(7), 1)
        XCTAssertEqual(Easing.easeOut(.infinity), 1)
        XCTAssertEqual(Easing.easeOut(-.infinity), 0)
    }

    func testNaNFinishesInsteadOfPoisoning() {
        XCTAssertEqual(Easing.easeOut(.nan), 1)
        XCTAssertEqual(Easing.hermite(.nan, s0: 2.4, s1: 0.6), 1)
        XCTAssertEqual(Easing.hermiteSlope(.nan, s0: 2.4, s1: 0.6), 0)
    }

    func testHermiteShapesUsedByProfilesAreMonotone() {
        for (s0, s1) in [(2.4, 0.6), (1.8, 0.8), (1.0, 1.0), (2.4, 0.0), (3.0, 0.0)] {
            var prev = 0.0
            for i in 1...200 {
                let v = Easing.hermite(Double(i) / 200, s0: s0, s1: s1)
                XCTAssertGreaterThanOrEqual(v, prev - 1e-12, "s0=\(s0) s1=\(s1) not monotone")
                prev = v
            }
            XCTAssertEqual(Easing.hermiteSlope(0, s0: s0, s1: s1), s0, accuracy: 1e-12)
            XCTAssertEqual(Easing.hermiteSlope(1, s0: s0, s1: s1), s1, accuracy: 1e-12)
        }
    }

    func testSlopeMatchesDerivative() {
        for x in stride(from: 0.05, to: 0.95, by: 0.1) {
            let h = 1e-6
            let numeric = (Easing.hermite(x + h, s0: 2.4, s1: 0.6) - Easing.hermite(x - h, s0: 2.4, s1: 0.6)) / (2 * h)
            XCTAssertEqual(Easing.hermiteSlope(x, s0: 2.4, s1: 0.6), numeric, accuracy: 1e-4)
        }
    }
}

final class CurveTests: XCTestCase {
    let high = ScrollProfile.make(smoothness: .high, speed: .medium, mode: .normal)

    func testDragTailClosedFormMatchesIntegration() {
        for b in [0.7, 1.0, 1.05] {
            let tail = DragTail(v0: 900, a: 40, b: b, stop: 30)
            var v = 900.0, x = 0.0, t = 0.0
            let dt = 1e-5
            while v > 30 { x += v * dt; v -= 40 * pow(v, b) * dt; t += dt }
            XCTAssertEqual(tail.distance, x, accuracy: x * 0.01, "b=\(b)")
            XCTAssertEqual(tail.duration, t, accuracy: t * 0.01, "b=\(b)")
            XCTAssertEqual(tail.position(at: tail.duration / 2), tail.covered(atSpeed: tail.speed(at: tail.duration / 2)), accuracy: 1e-9)
        }
        XCTAssertTrue(DragTail(v0: 10, a: 40, b: 0.7, stop: 30).isEmpty)
        XCTAssertTrue(DragTail(v0: .nan, a: 40, b: 0.7, stop: 30).isEmpty)
        XCTAssertEqual(DragTail(v0: .nan, a: 40, b: 0.7, stop: 30).distance, 0)
    }

    func testHybridIsExactContinuousAndHandsOffAtMatchingSpeed() {
        for d in [90.0, -90, 400, 2500] {
            let c = HybridCurve(distance: d, duration: 0.22, profile: high)
            XCTAssertEqual(c.position(at: 0), 0)
            XCTAssertEqual(c.position(at: c.duration), d, accuracy: 1e-9)
            XCTAssertEqual(c.position(at: .infinity), d)
            XCTAssertEqual(c.baseDistance + c.tailDistance, abs(d), accuracy: 1e-9)
            XCTAssertGreaterThan(c.tailDistance, 0, "High always ends in an inertia tail")
            let before = c.velocity(at: 0.22 - 1e-6), after = c.velocity(at: 0.22 + 1e-6)
            XCTAssertEqual(before, after, accuracy: abs(before) * 0.02 + 1, "speed must not jump at the hand-off")
            var prev = 0.0
            for i in 0...400 {
                let p = abs(c.position(at: c.duration * Double(i) / 400))
                XCTAssertGreaterThanOrEqual(p, prev - 1e-9); prev = p
            }
        }
    }

    func testOneMMFHighTickTakesAboutFourHundredMs() {
        let c = HybridCurve(distance: 90, duration: 0.22, profile: high)
        XCTAssertEqual(c.duration, 0.40, accuracy: 0.06)
    }

    func testNoTailProfileIsPureBase() {
        let z = ScrollProfile.zoom(speed: .medium)
        let c = HybridCurve(distance: 0.1, duration: z.baseDuration, profile: z)
        XCTAssertEqual(c.tailDistance, 0)
        XCTAssertEqual(c.duration, 0.25, accuracy: 1e-12)
    }

    func testNaNDistanceIsHarmless() {
        let c = HybridCurve(distance: .nan, duration: .nan, profile: high)
        XCTAssertEqual(c.total, 0)
        XCTAssertTrue(c.position(at: 0.1).isFinite)
    }
}

final class AnimatorTests: XCTestCase {
    let high = ScrollProfile.make(smoothness: .high, speed: .medium, mode: .normal)
    let low = ScrollProfile.make(smoothness: .low, speed: .medium, mode: .normal)

    /// Steps at 60 Hz until idle; returns everything emitted.
    func run(_ a: inout ScrollAnimator, from t0: Double, maxTime: Double = 5) -> [ScrollEmit] {
        var t = t0, out: [ScrollEmit] = []
        while a.isActive && t < t0 + maxTime {
            t += 1.0 / 60
            out += a.step(to: t, lookahead: 1.0 / 60).all
        }
        return out
    }

    func testSingleTickTrackpadSequence() {
        var a = ScrollAnimator()
        a.addTick(90, at: 0, duration: 0.22, profile: high)
        let first = a.step(to: 0, lookahead: 1.0 / 60).all
        XCTAssertEqual(first.first?.phase, .began)
        XCTAssertGreaterThan(first.first!.delta, 0, "first event must carry motion immediately (lookahead)")
        let all = first + run(&a, from: 0)
        XCTAssertEqual(all.map(\.delta).reduce(0, +), 90, accuracy: 1e-9, "exact distance")
        let phases = all.map(\.phase)
        let iEnded = phases.firstIndex(of: .ended)!, iMom = phases.firstIndex(of: .momentumBegan)!
        XCTAssertLessThan(iEnded, iMom, "gesture ends before momentum")
        XCTAssertTrue(phases[1..<iEnded].allSatisfy { $0 == .changed })
        XCTAssertEqual(Array(phases.suffix(3)), [.momentumEnded, .mayBegin, .cancelled])
        XCTAssertEqual(all[iEnded].delta, 0)
        XCTAssertFalse(a.isActive)
    }

    func testGesturePhaseLastsAtLeast160ms() {
        var a = ScrollAnimator()
        a.addTick(90, at: 0, duration: 0.11, profile: low)
        var t = 0.0, endedAt = -1.0
        while a.isActive && t < 2 {
            t += 0.001
            if a.step(to: t).all.contains(where: { $0.phase == .ended }) && endedAt < 0 { endedAt = t }
        }
        XCTAssertGreaterThanOrEqual(endedAt, ScrollAnimator.minGestureTime)
    }

    func testConsecutiveTicksCarryRemainderNoLossNoDuplication() {
        var a = ScrollAnimator(), total = 0.0
        for i in 0..<10 {
            a.addTick(60, at: Double(i) * 0.05, duration: 0.18, profile: low)
            total += a.step(to: Double(i) * 0.05 + 0.02).all.map(\.delta).reduce(0, +)
        }
        total += run(&a, from: 0.5).map(\.delta).reduce(0, +)
        XCTAssertEqual(total, 600, accuracy: 1e-9)
    }

    func testDirectionChangeCatchesAndStopsDead() {
        var a = ScrollAnimator()
        a.addTick(400, at: 0, duration: 0.22, profile: high)
        let partial = a.step(to: 0.02).all.map(\.delta).reduce(0, +)
        a.addTick(-90, at: 0.02, duration: 0.22, profile: high)
        let after = run(&a, from: 0.02).map(\.delta).reduce(0, +)
        XCTAssertEqual(after, -90, accuracy: 1e-9)
        XCTAssertLessThan(partial, 400)
    }

    func testTickDuringMomentumEndsMomentumThenBeginsNewGesture() {
        var a = ScrollAnimator()
        a.addTick(400, at: 0, duration: 0.22, profile: high)
        var t = 0.0
        while a.state != .momentum { t += 1.0 / 60; _ = a.step(to: t) }
        a.addTick(90, at: t, duration: 0.22, profile: high)
        let next = a.step(to: t + 0.001).all.map(\.phase)
        XCTAssertEqual(Array(next.prefix(2)), [.momentumEnded, .began])
    }

    func testFlingGlidesFurtherThanTheBasePush() {
        var a = ScrollAnimator()
        for i in 0..<8 { a.addTick(130, at: Double(i) * 0.03, duration: 0.22, profile: high); _ = a.step(to: Double(i) * 0.03) }
        let out = run(&a, from: 0.21)
        let momentum = out.filter { $0.phase.isMomentum }.map(\.delta).reduce(0, +)
        XCTAssertGreaterThan(momentum, 100, "a fling must coast")
        let m = out.filter { $0.phase == .momentumChanged }.map { abs($0.delta) }
        for (x, y) in zip(m, m.dropFirst()) { XCTAssertLessThanOrEqual(y, x + 1e-9, "momentum only decelerates") }
    }

    func testNaNAndInfinityInputsAreIgnored() {
        var a = ScrollAnimator()
        a.addTick(.nan, at: 0, duration: 0.22, profile: high)
        a.addTick(.infinity, at: 0, duration: 0.22, profile: high)
        a.addTick(40, at: .nan, duration: 0.22, profile: high)
        a.addTick(40, at: 0, duration: .nan, profile: high)
        XCTAssertFalse(a.isActive)
        a.addTick(40, at: 0, duration: 0.22, profile: high)
        XCTAssertEqual(a.step(to: .nan).count, 0)
        let out = run(&a, from: 0)
        XCTAssertTrue(out.allSatisfy { $0.delta.isFinite })
        XCTAssertEqual(out.map(\.delta).reduce(0, +), 40, accuracy: 1e-9)
    }

    func testClockGoingBackwardsNeverReverses() {
        var a = ScrollAnimator()
        a.addTick(90, at: 1, duration: 0.22, profile: high)
        let d1 = a.step(to: 1.1).all.map(\.delta).reduce(0, +)
        let d2 = a.step(to: 0.5).all.map(\.delta).reduce(0, +)
        XCTAssertGreaterThan(d1, 0)
        XCTAssertGreaterThanOrEqual(d1 + d2, 0, "never scrolls back past the start")
    }

    func testCancelClosesOpenGesture() {
        var a = ScrollAnimator()
        a.addTick(40, at: 0, duration: 0.22, profile: high)
        _ = a.step(to: 0.01)
        XCTAssertEqual(a.cancel().all.map(\.phase), [.ended])
        XCTAssertFalse(a.isActive)
        XCTAssertEqual(a.cancel().count, 0)
    }

    func testStepOutputCapacityNeverOverflows() {
        var o = StepOutput()
        for _ in 0..<20 { o.append(ScrollEmit(1, .changed)) }
        XCTAssertEqual(o.count, StepOutput.capacity)
    }

    func testQuantizerConservesDistance() {
        var q = Quantizer(), sum: Int32 = 0
        for _ in 0..<1000 { sum += q.take(0.37) }
        XCTAssertLessThanOrEqual(abs(sum - 370), 1, "only a sub-pixel remainder may be held back")
        var q2 = Quantizer(), s2: Int32 = 0
        for _ in 0..<1000 { s2 += q2.take(-0.37) }
        XCTAssertLessThanOrEqual(abs(s2 + 370), 1)
        XCTAssertEqual(q2.take(.nan), 0)
        XCTAssertEqual(q2.take(1e30), 1_000_000)
    }
}

final class AccelerationTests: XCTestCase {
    let p = ScrollProfile.make(smoothness: .high, speed: .medium, mode: .normal)

    func testIsolatedTicksAreMinDistance() {
        var acc = TickAccelerator()
        XCTAssertEqual(acc.distance(direction: 1, at: 0, profile: p), 90)
        XCTAssertEqual(acc.distance(direction: 1, at: 1, profile: p), 90)
        XCTAssertEqual(acc.distance(direction: -1, at: 2, profile: p), -90)
    }

    func testPixelsPerTickFollowSpinSpeed() {
        var slow = TickAccelerator(), fast = TickAccelerator()
        var ds = 0.0, df = 0.0
        for i in 0..<4 { ds = slow.distance(direction: 1, at: Double(i) * 0.15, profile: p) }
        for i in 0..<4 { df = fast.distance(direction: 1, at: Double(i) * 0.015, profile: p) }
        XCTAssertEqual(ds, 90, accuracy: 3, "6.7 ticks/s is barely above the floor")
        XCTAssertEqual(df, 180, accuracy: 1, "66.7 ticks/s reaches maxPx")
    }

    func testConsecutiveSwipesRampUp() {
        var acc = TickAccelerator()
        var perSwipe: [Double] = []
        var t = 0.0
        for _ in 0..<5 {
            var last = 0.0
            for _ in 0..<4 { last = acc.distance(direction: 1, at: t, profile: p); t += 0.03 }
            perSwipe.append(last)
            t += 0.3 // gap between swipes < 600 ms
        }
        XCTAssertEqual(perSwipe[0], perSwipe[1], accuracy: 1e-9, "ramp starts at the 3rd swipe (t = 2)")
        XCTAssertEqual(perSwipe[2] / perSwipe[1], 1.33, accuracy: 0.01)
        XCTAssertGreaterThan(perSwipe[4], perSwipe[3])
        XCTAssertEqual(acc.consecutiveSwipes, 4)
    }

    func testPauseOrDirectionChangeResets() {
        var acc = TickAccelerator()
        var t = 0.0
        for _ in 0..<4 { for _ in 0..<4 { _ = acc.distance(direction: 1, at: t, profile: p); t += 0.03 }; t += 0.3 }
        XCTAssertGreaterThan(acc.consecutiveSwipes, 2)
        XCTAssertEqual(acc.distance(direction: -1, at: t, profile: p), -90)
        XCTAssertEqual(acc.consecutiveSwipes, 0)
        _ = acc.distance(direction: 1, at: t + 5, profile: p)
        XCTAssertEqual(acc.consecutiveSwipes, 0)
    }

    func testPreciseIsSmallAndFlat() {
        let pr = ScrollProfile.make(smoothness: .high, speed: .medium, mode: .precise)
        var acc = TickAccelerator()
        for i in 0..<30 { XCTAssertLessThanOrEqual(abs(acc.distance(direction: 1, at: Double(i) * 0.2, profile: pr)), 20) }
        XCTAssertEqual(acc.distance(direction: 1, at: 100, profile: pr), 10)
        XCTAssertNil(pr.speedup)
    }

    func testSpeedAndModeOrdering() {
        let s = ScrollProfile.make(smoothness: .high, speed: .slow, mode: .normal)
        let m = ScrollProfile.make(smoothness: .high, speed: .medium, mode: .normal)
        let f = ScrollProfile.make(smoothness: .high, speed: .fast, mode: .normal)
        let sw = ScrollProfile.make(smoothness: .high, speed: .medium, mode: .swift, screenHeight: 900)
        XCTAssertLessThan(s.minPx, m.minPx); XCTAssertLessThan(m.minPx, f.minPx)
        XCTAssertGreaterThan(sw.minPx, f.maxPx)
        XCTAssertEqual(sw.minPx, 0.5 * 900 * 0.85, accuracy: 1e-9)
        XCTAssertEqual(ScrollProfile.make(smoothness: .off, speed: .medium, mode: .normal).baseDuration, 0)
        XCTAssertFalse(ScrollProfile.make(smoothness: .off, speed: .medium, mode: .normal).smooth)
        XCTAssertEqual(ScrollProfile.make(smoothness: .high, speed: .medium, mode: .swift, screenHeight: .nan).minPx, 0.5 * 900 * 0.85, accuracy: 1e-9)
    }

    func testLowDurationShrinksWithFasterTicks() {
        let lo = ScrollProfile.make(smoothness: .low, speed: .medium, mode: .normal)
        XCTAssertEqual(lo.duration(tickInterval: .infinity), 0.18)
        XCTAssertEqual(lo.duration(tickInterval: 0.2), 0.18)
        XCTAssertEqual(lo.duration(tickInterval: 0.001), 0.11, accuracy: 1e-9)
        XCTAssertLessThan(lo.duration(tickInterval: 0.02), lo.duration(tickInterval: 0.1))
        XCTAssertEqual(lo.duration(tickInterval: .nan), 0.18)
        XCTAssertEqual(p.duration(tickInterval: 0.01), 0.22, "High has a fixed base curve")
    }

    func testSpeedupRampClampsAndHandlesNaN() {
        let r = SpeedupRamp(t: 2, p: 1.33, c: 7.5)
        XCTAssertEqual(r.factor(swipes: 1), 1)
        XCTAssertEqual(r.factor(swipes: 2), 1, accuracy: 1e-12)
        XCTAssertEqual(r.factor(swipes: 3), 1.33, accuracy: 1e-9)
        XCTAssertEqual(r.factor(swipes: 1000), 50)
        XCTAssertEqual(r.factor(swipes: .nan), 1)
    }
}

final class ModifierTests: XCTestCase {
    let m = ScrollModifiers()

    func testDefaults() {
        XCTAssertEqual(m.mode(for: []), ScrollMode())
        XCTAssertTrue(m.mode(for: .command).zoom)
        XCTAssertEqual(m.mode(for: .option).speed, .precise)
        XCTAssertTrue(m.mode(for: .shift).horizontal)
        XCTAssertEqual(m.mode(for: .control).speed, .swift)
    }

    func testCombinations() {
        let ps = m.mode(for: [.option, .shift])
        XCTAssertTrue(ps.horizontal); XCTAssertEqual(ps.speed, .precise)
        let zoomWins = m.mode(for: [.command, .shift, .control])
        XCTAssertTrue(zoomWins.zoom); XCTAssertFalse(zoomWins.horizontal); XCTAssertEqual(zoomWins.speed, .normal)
        XCTAssertEqual(m.mode(for: [.option, .control]).speed, .precise)
    }

    func testConsumedFlagsAreStripped() {
        XCTAssertEqual(m.mode(for: .shift).consumedFlags, 1 << 17)
        XCTAssertEqual(m.mode(for: [.command, .option]).consumedFlags, (1 << 20) | (1 << 19))
        var custom = ScrollModifiers(); custom.shift = .none
        XCTAssertEqual(custom.mode(for: .shift), ScrollMode(), "unmapped modifier passes through untouched")
    }

    func testCGFlagParsing() {
        let flags: UInt64 = (1 << 20) | (1 << 17) | 0x100 // cmd + shift + device bits
        XCTAssertEqual(HeldModifiers(cgFlags: flags), [.command, .shift])
        XCTAssertEqual(HeldModifiers(cgFlags: 0), [])
    }
}

final class SettingsTests: XCTestCase {
    func suite() -> UserDefaults {
        let name = "glide.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsMatchMelvernsMacMouseFixSetup() {
        let s = GlideSettings()
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.smoothness, .high)
        XCTAssertEqual(s.speed, .medium)
        XCTAssertTrue(s.reverseDirection)
        XCTAssertTrue(s.trackpadSimulation)
        XCTAssertEqual(s.modifiers.command, .zoom)
        XCTAssertEqual(s.modifiers.option, .precise)
        XCTAssertEqual(s.modifiers.shift, .horizontal)
        XCTAssertEqual(s.modifiers.control, .swift)
        XCTAssertFalse(s.remapsEnabled)
        XCTAssertTrue(s.interceptedButtons.isEmpty, "no button is touched out of the box")
        XCTAssertNil(s.dragGestureButton); XCTAssertNil(s.scrollGestureButton)
    }

    func testRoundTrip() {
        let store = SettingsStore(defaults: suite())
        var s = GlideSettings()
        s.smoothness = .low; s.speed = .fast; s.reverseDirection = false
        s.remapsEnabled = true
        s.remaps = [ButtonRemap(button: .button4, trigger: .click, action: .back),
                    ButtonRemap(button: .middle, trigger: .hold, action: .shortcut(KeyShortcut(keyCode: 49, modifiers: 1 << 20)))]
        s.dragGestureButton = .button5
        s.exceptions = [AppException(bundleID: "com.valvesoftware.steam", name: "Steam")]
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testEmptyAndGarbageFallBackToDefaults() {
        let d = suite()
        XCTAssertEqual(SettingsStore(defaults: d).load(), GlideSettings())
        d.set(Data("not json".utf8), forKey: SettingsStore.key)
        XCTAssertEqual(SettingsStore(defaults: d).load(), GlideSettings())
        d.set(Data("{}".utf8), forKey: SettingsStore.key)
        XCTAssertEqual(SettingsStore(defaults: d).load(), GlideSettings())
    }

    func testPartialAndMalformedKeysKeepTheRest() {
        let d = suite()
        let json = """
        {"smoothness":"medium","speed":"warp","reverseDirection":false,
         "remaps":[{"button":4,"trigger":"click","action":{"back":{}}},{"button":99,"trigger":"x"}],
         "exceptions":[{"bundleID":"","name":"x","disableSmoothing":true},{"bundleID":"com.game","name":"G","disableSmoothing":true}]}
        """
        d.set(Data(json.utf8), forKey: SettingsStore.key)
        let s = SettingsStore(defaults: d).load()
        XCTAssertEqual(s.smoothness, .medium)
        XCTAssertEqual(s.speed, .medium, "unknown enum value falls back")
        XCTAssertFalse(s.reverseDirection)
        XCTAssertEqual(s.remaps, [ButtonRemap(button: .button4, trigger: .click, action: .back)])
        XCTAssertEqual(s.exceptions.map(\.bundleID), ["com.game"])
        XCTAssertTrue(s.smoothingDisabled(forBundleID: "com.game"))
        XCTAssertFalse(s.smoothingDisabled(forBundleID: "com.apple.Safari"))
        XCTAssertFalse(s.smoothingDisabled(forBundleID: nil))
    }

    func testInterceptedButtonsOnlyWhenEnabled() {
        var s = GlideSettings()
        s.remaps = [ButtonRemap(button: .button4, trigger: .click, action: .missionControl)]
        XCTAssertTrue(s.interceptedButtons.isEmpty)
        s.remapsEnabled = true
        XCTAssertEqual(s.interceptedButtons, [.button4])
        s.scrollGestureButton = .button5
        XCTAssertEqual(s.interceptedButtons, [.button4, .button5])
    }

    func testButtonNumbering() {
        XCTAssertEqual(MouseButton.middle.cgButtonNumber, 2)
        XCTAssertEqual(MouseButton(cgButtonNumber: 3), .button4)
        XCTAssertNil(MouseButton(cgButtonNumber: 0))
    }

    func testShortcutFormatting() {
        XCTAssertEqual(ShortcutFormatter.string(KeyShortcut(keyCode: 49, modifiers: (1 << 20) | (1 << 17))), "⇧⌘Space")
        XCTAssertEqual(ShortcutFormatter.string(KeyShortcut(keyCode: 0, modifiers: 1 << 18)), "⌃A")
    }
}
