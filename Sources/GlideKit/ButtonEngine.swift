import Foundation

/// Everything Glide does with one mouse button, flattened from `GlideSettings`.
public struct ButtonConfig: Equatable, Sendable {
    public var click: ButtonAction?
    public var doubleClick: ButtonAction?
    public var hold: ButtonAction?
    /// Hold + drag = gesture (three-finger swipe).
    public var drag: Bool
    /// Hold + scroll = gesture (pinch to zoom).
    public var scroll: Bool

    public init(click: ButtonAction? = nil, doubleClick: ButtonAction? = nil, hold: ButtonAction? = nil,
                drag: Bool = false, scroll: Bool = false) {
        self.click = click; self.doubleClick = doubleClick; self.hold = hold
        self.drag = drag; self.scroll = scroll
    }

    /// True when the button has nothing configured at all.
    public var isEmpty: Bool { click == nil && doubleClick == nil && hold == nil && !drag && !scroll }
}

extension GlideSettings {
    /// Per-button configuration built from the active remaps (`.none` actions are ignored) and the
    /// drag/scroll gesture buttons. Buttons with nothing configured are absent.
    /// If several remaps target the same button + trigger, the last one wins.
    public var buttonConfigs: [MouseButton: ButtonConfig] {
        var out: [MouseButton: ButtonConfig] = [:]
        for r in activeRemaps where r.action != .none {
            var c = out[r.button] ?? ButtonConfig()
            switch r.trigger {
            case .click: c.click = r.action
            case .doubleClick: c.doubleClick = r.action
            case .hold: c.hold = r.action
            }
            out[r.button] = c
        }
        if let b = dragGestureButton { out[b, default: ButtonConfig()].drag = true }
        if let b = scrollGestureButton { out[b, default: ButtonConfig()].scroll = true }
        return out.filter { !$0.value.isEmpty }
    }
}

/// Raw input fed to the engine by the event tap. Times are in seconds on any monotonic clock.
public enum ButtonInput: Equatable, Sendable {
    case down(MouseButton, t: Double)
    case up(MouseButton, t: Double)
    case drag(MouseButton, dx: Double, dy: Double, t: Double)
    /// A wheel tick while this button is held (only meaningful if it has the scroll gesture).
    case scroll(MouseButton, t: Double)
    /// Wake-up call, requested through `nextDeadline`.
    case timer(t: Double)
}

/// What the app layer should do in response to an input.
public enum ButtonOutput: Equatable, Sendable {
    /// Re-post the original down + up (plain click on an intercepted button).
    case passClick(MouseButton)
    /// Re-post the original press / release separately (plain long press with no hold action).
    case passDown(MouseButton), passUp(MouseButton)
    case action(ButtonAction)
    case dragBegan(MouseButton), dragMoved(dx: Double, dy: Double), dragEnded(MouseButton)
    case scrollGestureBegan(MouseButton), scrollGestureEnded(MouseButton)
}

/// Pure state machine turning button presses into clicks, double clicks, holds and gestures.
/// It never reads a clock: time only advances through the `t` of inputs. The owner must send a
/// `.timer` input at (or after) `nextDeadline` whenever that is non-nil.
public struct ButtonEngine: Sendable {
    public let configs: [MouseButton: ButtonConfig]
    public let holdDelay: Double
    public let doubleClickWindow: Double
    public let dragThreshold: Double

    /// The press currently held down.
    private struct Press: Sendable {
        var button: MouseButton
        /// When the hold action (or the delayed passDown) is due; nil once handled or not needed.
        var holdDeadline: Double?
        var dx = 0.0, dy = 0.0
        /// Consumed by hold / drag / scroll / passDown: release must not produce a click.
        var used = false
        var dragging = false
        var scrolling = false
        var passedDown = false
        /// This press is the second click of a potential double click.
        var isSecondClick = false
    }

    /// A finished click waiting to see whether a second click follows.
    private struct PendingClick: Sendable {
        var button: MouseButton
        var deadline: Double
    }

    private var press: Press?
    private var pending: PendingClick?
    /// Latest valid time seen; invalid or backwards times are clamped to it.
    private var now = 0.0

    public init(configs: [MouseButton: ButtonConfig], holdDelay: Double = 0.30,
                doubleClickWindow: Double = 0.30, dragThreshold: Double = 7) {
        self.configs = configs.filter { !$0.value.isEmpty }
        self.holdDelay = Self.sanePositive(holdDelay, fallback: 0.30)
        self.doubleClickWindow = Self.sanePositive(doubleClickWindow, fallback: 0.30)
        self.dragThreshold = dragThreshold.isFinite && dragThreshold >= 0 ? dragThreshold : 7
    }

    public func intercepts(_ b: MouseButton) -> Bool { configs[b] != nil }

    /// Earliest time a `.timer` input is needed, nil if none.
    public var nextDeadline: Double? {
        let hold = press.flatMap { $0.used ? nil : $0.holdDeadline }
        switch (hold, pending?.deadline) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    public mutating func handle(_ input: ButtonInput) -> [ButtonOutput] {
        switch input {
        case let .down(b, t):
            guard let config = configs[b] else { return [] }
            return handleDown(b, config: config, t: clamp(t))
        case let .up(b, t):
            guard let config = configs[b] else { return [] }
            return handleUp(b, config: config, t: clamp(t))
        case let .drag(b, dx, dy, t):
            guard let config = configs[b] else { return [] }
            return handleDrag(b, config: config, dx: dx, dy: dy, t: clamp(t))
        case let .scroll(b, t):
            guard let config = configs[b] else { return [] }
            return handleScroll(b, config: config, t: clamp(t))
        case let .timer(t):
            return fireDue(at: clamp(t))
        }
    }

    /// Ends any running gesture (and releases a passed-through press so nothing stays stuck down),
    /// then forgets all state. Pending single clicks are dropped.
    public mutating func reset() -> [ButtonOutput] {
        let out = press.map(endPress) ?? []
        press = nil
        pending = nil
        return out
    }

    // MARK: - Input handlers

    private mutating func handleDown(_ b: MouseButton, config: ButtonConfig, t: Double) -> [ButtonOutput] {
        var out = fireDue(at: t)
        // A down while something is still pressed (lost up event): close the old press cleanly.
        if let old = press {
            out += endPress(old)
            press = nil
        }
        var p = Press(button: b)
        if let pc = pending {
            if pc.button == b {
                // Still inside the window (fireDue would have flushed it otherwise): second click.
                p.isSecondClick = true
            } else {
                // Another button interrupts: settle the first button's click now, in order.
                out += singleClick(pc.button)
            }
            pending = nil
        }
        if config.hold != nil || config.drag || config.scroll {
            p.holdDeadline = t + holdDelay
        }
        press = p
        return out
    }

    private mutating func handleUp(_ b: MouseButton, config: ButtonConfig, t: Double) -> [ButtonOutput] {
        // Fire a hold that is already due, in case the timer input came late or not at all.
        var out = fireDue(at: t)
        guard let p = press, p.button == b else { return out }
        press = nil
        if p.used { return out + endPress(p) }
        if config.doubleClick != nil {
            if p.isSecondClick {
                out.append(.action(config.doubleClick!))
            } else {
                pending = PendingClick(button: b, deadline: t + doubleClickWindow)
            }
        } else {
            out += singleClick(b)
        }
        return out
    }

    private mutating func handleDrag(_ b: MouseButton, config: ButtonConfig, dx: Double, dy: Double, t: Double) -> [ButtonOutput] {
        guard config.drag, dx.isFinite, dy.isFinite else { return [] }
        var out = fireDue(at: t)
        guard var p = press, p.button == b else { return out }
        if p.dragging {
            out.append(.dragMoved(dx: dx, dy: dy))
            return out
        }
        // Already consumed by a hold / scroll / passDown: no drag gesture for this press.
        guard !p.used else { return out }
        p.dx += dx
        p.dy += dy
        if (p.dx * p.dx + p.dy * p.dy).squareRoot() > dragThreshold {
            out += consume(&p)
            p.dragging = true
            out.append(.dragBegan(b))
            out.append(.dragMoved(dx: dx, dy: dy))
        }
        press = p
        return out
    }

    private mutating func handleScroll(_ b: MouseButton, config: ButtonConfig, t: Double) -> [ButtonOutput] {
        guard config.scroll else { return [] }
        var out = fireDue(at: t)
        guard var p = press, p.button == b, !p.used else { return out }
        out += consume(&p)
        p.scrolling = true
        out.append(.scrollGestureBegan(b))
        press = p
        return out
    }

    // MARK: - Helpers

    /// Fires every deadline that is due at `t`: the oldest (pending click) first, then the hold.
    private mutating func fireDue(at t: Double) -> [ButtonOutput] {
        var out: [ButtonOutput] = []
        if let pc = pending, t >= pc.deadline {
            pending = nil
            out += singleClick(pc.button)
        }
        if var p = press, !p.used, let deadline = p.holdDeadline, t >= deadline {
            out += consume(&p)
            if let hold = configs[p.button]?.hold {
                out.append(.action(hold))
            } else {
                // Gesture button held still: hand the long press to apps after all.
                p.passedDown = true
                out.append(.passDown(p.button))
            }
            press = p
        }
        return out
    }

    /// Marks a press as used. If it was the second click of a would-be double click, the first
    /// click was swallowed when this press began; give it back so it isn't lost.
    private func consume(_ p: inout Press) -> [ButtonOutput] {
        p.used = true
        p.holdDeadline = nil
        guard p.isSecondClick else { return [] }
        p.isSecondClick = false
        return singleClick(p.button)
    }

    /// Outputs that close a press that is going away.
    private func endPress(_ p: Press) -> [ButtonOutput] {
        if p.dragging { return [.dragEnded(p.button)] }
        if p.scrolling { return [.scrollGestureEnded(p.button)] }
        if p.passedDown { return [.passUp(p.button)] }
        return []
    }

    private func singleClick(_ b: MouseButton) -> [ButtonOutput] {
        if let click = configs[b]?.click { return [.action(click)] }
        return [.passClick(b)]
    }

    /// NaN, infinite, negative or backwards times are replaced by the latest valid time.
    private mutating func clamp(_ t: Double) -> Double {
        if t.isFinite, t >= 0, t > now { now = t }
        return now
    }

    private static func sanePositive(_ v: Double, fallback: Double) -> Double {
        v.isFinite && v > 0 ? v : fallback
    }
}
