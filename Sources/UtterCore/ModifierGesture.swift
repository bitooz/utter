import Foundation

/// Turns presses of one modifier key (Option by default) into dictation gestures, without touching the key itself:
///
/// - hold it alone for `holdDelay` → `.holdBegan`, release → `.holdEnded`
/// - a quick tap of it alone → `.tap`; a second press soon after a tap → `.doubleTap` (when `doubleTaps` is on)
/// - any other key, modifier, click or scroll while it is down makes it a shortcut, not a gesture;
///   if a hold had already begun, that yields `.interrupted`
///
/// Pure state machine (times in seconds, any monotonic clock) so it can be tested without a keyboard.
public struct ModifierGesture {
    public enum Event: Equatable { case holdBegan, holdEnded, tap, doubleTap, interrupted }

    public var holdDelay: TimeInterval = 0.3
    public var doubleTapGap: TimeInterval = 0.35
    /// Off when this key only holds to talk, so a quick tap-then-hold still starts a hold.
    public var doubleTaps = true

    public private(set) var isDown = false
    /// Bumped on every press; pass it back to `holdTimer` so a stale timer does nothing.
    public private(set) var generation = 0
    private var downAt: TimeInterval = 0
    private var clean = false      // the key alone so far during this press
    private var held = false       // `.holdBegan` sent for this press
    private var secondTap = false  // this press was the second half of a double tap
    private var lastTapUp: TimeInterval?

    public init() {}

    /// The key went down. `alone`: no other modifier is held with it.
    public mutating func optionDown(alone: Bool, at t: TimeInterval) -> [Event] {
        guard !isDown else { return [] }
        isDown = true
        downAt = t
        clean = alone
        held = false
        secondTap = false
        generation += 1
        if doubleTaps, alone, let up = lastTapUp, t - up <= doubleTapGap {
            lastTapUp = nil
            secondTap = true
            return [.doubleTap]
        }
        lastTapUp = nil
        return []
    }

    /// Call `holdDelay` after `optionDown`, with the generation current at that press.
    public mutating func holdTimer(generation g: Int, at t: TimeInterval) -> [Event] {
        guard g == generation, isDown, clean, !held, !secondTap, t - downAt >= holdDelay - 0.005 else { return [] }
        held = true
        return [.holdBegan]
    }

    /// The key is up.
    public mutating func optionUp(at t: TimeInterval) -> [Event] {
        guard isDown else { return [] }
        isDown = false
        lastTapUp = nil
        if held { held = false; return [.holdEnded] }
        guard clean else { return [] }
        if secondTap {
            // Tap then hold: the long second press ends the dictation it started, like a hold.
            return t - downAt >= holdDelay ? [.holdEnded] : []
        }
        if t - downAt < holdDelay { lastTapUp = t; return [.tap] }
        return []
    }

    /// Any other key, modifier, mouse click or scroll.
    public mutating func otherInput(at t: TimeInterval) -> [Event] {
        lastTapUp = nil
        guard isDown, clean else { return [] }
        clean = false
        if held { held = false; return [.interrupted] }
        return []
    }
}
