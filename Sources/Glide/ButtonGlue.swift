import AppKit
import GlideKit

/// Glue between the tap and button remaps / gestures. M1 stub: everything passes through.
final class ButtonGlue {
    unowned let engine: Engine
    init(engine: Engine) { self.engine = engine }
    func settingsChanged() {}
    /// Returns true if consumed.
    func handle(type: CGEventType, event: CGEvent) -> Bool { false }
    /// Scroll while a gesture button is held. Returns true if consumed.
    func scrollWhileHeld(_ e: CGEvent, delta: Int64) -> Bool { false }
}
