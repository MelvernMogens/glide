import AppKit
import ApplicationServices
import GlideKit

/// Builds and posts synthetic input events. Field numbers come from reverse-engineered
/// trackpad output (same values Mac Mouse Fix uses); see docs/event-synthesis.md.
enum Synth {
    // Undocumented / numeric CGEventField ids
    static let fType = CGEventField(rawValue: 55)!
    static let fGestureHIDType = CGEventField(rawValue: 110)!
    static let fGesturePhase = CGEventField(rawValue: 132)!
    static let fGestureScrollX = CGEventField(rawValue: 116)!
    static let fGestureScrollY = CGEventField(rawValue: 119)!
    static let fMagnification = CGEventField(rawValue: 113)!
    static let fSwipeDirection = CGEventField(rawValue: 115)!
    static let fInvertedFromDevice = CGEventField(rawValue: 137)!

    static let gestureType: Int64 = 29 // NSEventTypeGesture
    // IOHIDEventType values
    static let hidScroll: Int64 = 6, hidZoom: Int64 = 8, hidNavSwipe: Int64 = 16, hidZoomToggle: Int64 = 22

    // IOHIDEventPhaseBits
    static func hidPhase(_ p: ScrollPhase) -> Int64 {
        switch p {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        case .cancelled: return 8
        case .mayBegin: return 128
        default: return 0
        }
    }

    // CGMomentumScrollPhase
    static func momentumPhase(_ p: ScrollPhase) -> Int64 {
        switch p {
        case .momentumBegan: return 1
        case .momentumChanged: return 2
        case .momentumEnded: return 3
        default: return 0
        }
    }

    static var invertedFromDevice: Int64 = 1

    /// Test harness only (GLIDE_TARGET=pid,windowID,x,y): deliver output straight to one app window
    /// instead of routing by pointer location, so real apps can be measured off-screen without
    /// touching the user's pointer or front window.
    static let testTarget: (pid: pid_t, window: Int64, at: CGPoint)? = {
        guard let v = ProcessInfo.processInfo.environment["GLIDE_TARGET"] else { return nil }
        let p = v.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return (pid_t(p[0]), Int64(p[1]), CGPoint(x: p[2], y: p[3]))
    }()

    @inline(__always) static func send(_ e: CGEvent, _ tap: CGEventTapLocation) {
        if let t = testTarget {
            e.location = t.at
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: t.window)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: t.window)
            e.postToPid(t.pid)
        } else {
            e.post(tap: tap)
        }
    }

    /// Posts one continuous (pixel) scroll event. With `phase` set, it is trackpad-like
    /// (gesture or momentum phase + companion gesture event) so apps rubber-band and glide.
    static func scroll(dy: Int32, dx: Int32, phase: ScrollPhase?, flags: UInt64) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        let loc = cursor()
        e.location = loc
        e.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        e.flags = CGEventFlags(rawValue: flags)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Line deltas the way the trackpad driver rounds them: |x| <= 1 rounds away from zero.
        let ly = Double(dy) / 10, lx = Double(dx) / 10
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineInt(ly))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineInt(lx))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: ly)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: lx)
        e.setIntegerValueField(fInvertedFromDevice, value: invertedFromDevice)
        let isGesturePhase: Bool
        if let phase {
            isGesturePhase = !phase.isMomentum
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: isGesturePhase ? hidPhase(phase) : 0)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: isGesturePhase ? 0 : momentumPhase(phase))
        } else {
            isGesturePhase = false
        }
        send(e, .cgSessionEventTap)

        if let phase, isGesturePhase, let g = CGEvent(source: nil) {
            g.setIntegerValueField(fType, value: gestureType)
            g.location = loc
            g.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
            g.flags = CGEventFlags(rawValue: flags)
            g.setIntegerValueField(fGestureHIDType, value: hidScroll)
            let gx = Double(dx) * 1.67, gy = Double(dy) * 1.67
            g.setDoubleValueField(fGestureScrollX, value: gx == 0 ? -0.0 : gx)
            g.setDoubleValueField(fGestureScrollY, value: gy == 0 ? -0.0 : gy)
            g.setIntegerValueField(fGesturePhase, value: hidPhase(phase))
            send(g, .cgSessionEventTap)
        }
    }

    /// Current pointer position (events are routed to the window under their location).
    static func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    @inline(__always) static func lineInt(_ v: Double) -> Int64 {
        if v == 0 { return 0 }
        if abs(v) <= 1 { return v > 0 ? 1 : -1 }
        return Int64(v.rounded(.towardZero))
    }

    /// Pinch-to-zoom gesture step.
    static func magnify(_ e: ScrollEmit) {
        let phase: Int64
        switch e.phase {
        case .began: phase = 1
        case .changed: phase = 2
        case .ended: phase = 4
        default: return
        }
        guard let g = CGEvent(source: nil) else { return }
        g.setIntegerValueField(fType, value: gestureType)
        g.location = cursor()
        g.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        g.setIntegerValueField(fGestureHIDType, value: hidZoom)
        g.setIntegerValueField(fGesturePhase, value: phase)
        g.setDoubleValueField(fMagnification, value: e.delta)
        send(g, .cghidEventTap)
    }

    /// Double-tap "smart zoom".
    static func smartZoom() {
        guard let g = CGEvent(source: nil) else { return }
        g.setIntegerValueField(fType, value: gestureType)
        g.location = cursor()
        g.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        g.setIntegerValueField(fGestureHIDType, value: hidZoomToggle)
        send(g, .cghidEventTap)
    }

    /// Back / forward page swipe (IOHIDSwipeMask: left = 1<<2, right = 1<<3).
    static func navigationSwipe(back: Bool) {
        guard let g = CGEvent(source: nil) else { return }
        g.setIntegerValueField(fType, value: gestureType)
        g.location = cursor()
        g.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        g.setIntegerValueField(fGestureHIDType, value: hidNavSwipe)
        g.setIntegerValueField(fGesturePhase, value: 1)
        g.setIntegerValueField(fSwipeDirection, value: back ? 1 << 2 : 1 << 3)
        send(g, .cghidEventTap)
        g.setIntegerValueField(fSwipeDirection, value: 0)
        g.setIntegerValueField(fGesturePhase, value: 4)
        send(g, .cghidEventTap)
    }

    /// Key press + release with modifiers.
    static func key(_ code: UInt16, flags: UInt64) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let k = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            k.flags = CGEventFlags(rawValue: flags)
            k.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
            k.post(tap: .cghidEventTap)
        }
    }

    /// Middle click at the cursor.
    static func middleClick(down: Bool) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        guard let m = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                              mouseCursorPosition: loc, mouseButton: .center) else { return }
        m.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        m.post(tap: .cgSessionEventTap)
    }

    /// Re-post an original button event we held back (so a remapped button's plain click still works).
    static func repostButton(_ number: Int64, down: Bool) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        guard let m = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                              mouseCursorPosition: loc, mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .center) else { return }
        m.setIntegerValueField(.mouseEventButtonNumber, value: number)
        m.setIntegerValueField(.eventSourceUserData, value: kGlideMark)
        m.post(tap: .cgSessionEventTap)
    }
}
