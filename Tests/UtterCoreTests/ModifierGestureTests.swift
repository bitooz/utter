import XCTest
@testable import UtterCore

/// Drives `ModifierGesture` the way HotkeyTap does: the hold timer fires `holdDelay` after each Option press.
final class ModifierGestureTests: XCTestCase {
    private var g = ModifierGesture()
    private var events: [ModifierGesture.Event] = []
    private var timer: (gen: Int, at: Double)?

    private func down(_ t: Double, alone: Bool = true) {
        fire(upTo: t)
        events += g.optionDown(alone: alone, at: t)
        if alone && g.isDown { timer = (g.generation, t + g.holdDelay) }
    }
    private func up(_ t: Double) { fire(upTo: t); events += g.optionUp(at: t) }
    private func other(_ t: Double) { fire(upTo: t); events += g.otherInput(at: t) }
    private func fire(upTo t: Double) {
        if let tm = timer, tm.at <= t { events += g.holdTimer(generation: tm.gen, at: tm.at); timer = nil }
    }

    func testHoldTalksAndReleasePastes() {
        down(0); up(2.0)
        XCTAssertEqual(events, [.holdBegan, .holdEnded])
    }

    func testShortHoldDoesNothing() {
        down(0); up(0.29)
        XCTAssertEqual(events, [.tap])
    }

    func testOptionShortcutQuickly() { // ⌥← word jump, ⌥⌫, ⌥-typing: key inside the hold delay
        down(0); other(0.1); up(0.2)
        down(5); other(5.15); other(5.2); up(5.6)
        XCTAssertEqual(events, [])
    }

    func testOptionShortcutAfterHoldBegan() { // held Option a while, then pressed a key: drop the recording
        down(0); other(0.8); up(1.0)
        XCTAssertEqual(events, [.holdBegan, .interrupted])
    }

    func testOptionClick() {
        down(0); other(0.2); up(0.6)
        XCTAssertEqual(events, [])
    }

    func testOptionWithOtherModifierNeverStarts() { // ⇧⌥ or ⌘⌥ held first
        down(0, alone: false); up(1.0)
        XCTAssertEqual(events, [])
    }

    func testDoubleTapStartsHandsFreeAndTapEnds() {
        down(0); up(0.1); down(0.3); up(0.4)
        XCTAssertEqual(events, [.tap, .doubleTap])
        events = []
        down(5); up(5.1)
        XCTAssertEqual(events, [.tap])
    }

    func testSlowSecondTapIsNotDouble() {
        down(0); up(0.1); down(0.6); up(0.7)
        XCTAssertEqual(events, [.tap, .tap])
    }

    func testTypingBetweenTapsBreaksDouble() {
        down(0); up(0.1); other(0.2); down(0.3); up(0.4)
        XCTAssertEqual(events, [.tap, .tap])
    }

    func testTapThenHoldEndsOnRelease() { // second press held: hands-free begins at once, release ends it
        down(0); up(0.1); down(0.3); up(3.0)
        XCTAssertEqual(events, [.tap, .doubleTap, .holdEnded])
    }

    func testTapThenHoldStartsHoldWithoutDoubleTaps() { // hold-only key: tap-then-hold is just a hold
        g.doubleTaps = false
        down(0); up(0.1); down(0.3); up(2.0)
        XCTAssertEqual(events, [.tap, .holdBegan, .holdEnded])
    }

    func testStaleTimerIgnored() { // timer from a first press must not fire during a later one
        down(0); up(0.1)
        let stale = timer!; timer = nil
        down(0.31, alone: false)
        events += g.holdTimer(generation: stale.gen, at: stale.at)
        XCTAssertFalse(events.contains(.holdBegan))
    }
}
