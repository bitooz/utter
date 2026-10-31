import XCTest
import CoreGraphics
import UtterCore
@testable import Utter

/// The real `HotkeyTap`, fed events by hand (no event tap, no keyboard).
final class HotkeyTapTests: XCTestCase {
    private let fn: UInt64 = 0x800000

    private func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func flags(_ tap: HotkeyTap, _ code: CGKeyCode, _ f: UInt64) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: f)
        _ = tap.handle(.flagsChanged, e)
    }

    /// Holds fn (Auto's key), lets `during` happen mid-hold, lets go; returns what the tap reported.
    private func holdFn(_ during: (HotkeyTap) -> Void) -> [String] {
        let tap = HotkeyTap()
        var now: UInt64 = 0
        tap.currentFlags = { now }
        tap.configure([(.auto, .modifier(.fn))])
        var got: [String] = []
        tap.onTrigger = { got.append("\($0.kind)") }
        now = fn; flags(tap, 63, fn)
        wait(0.45) // the hold has begun
        during(tap)
        wait(0.1)
        now = 0; flags(tap, 63, 0)
        wait(0.1)
        return got
    }

    /// Utter's own ⌘V (a paste landing while the next dictation's key is held) is not the user pressing a key:
    /// it passes through and the dictation carries on.
    func testUttersOwnPasteDoesNotBreakAHeldKey() throws {
        var passed: [Bool] = []
        let got = holdFn { tap in
            let v = Paster.commandV()!
            XCTAssertTrue(Paster.isOwn(v.down) && Paster.isOwn(v.up))
            passed.append(tap.handle(.keyDown, v.down) != nil)
            passed.append(tap.handle(.keyUp, v.up) != nil)
        }
        XCTAssertEqual(got, ["holdBegan", "holdEnded"])
        XCTAssertEqual(passed, [true, true], "the paste itself must reach the app")
    }

    /// The same ⌘V typed by the user does make the held key a shortcut (so the check above is not trivially true).
    func testTheUsersOwnCommandVStillCountsAsAShortcut() {
        let got = holdFn { tap in
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
            e.flags = CGEventFlags(rawValue: fn | CGEventFlags.maskCommand.rawValue)
            _ = tap.handle(.keyDown, e)
        }
        XCTAssertEqual(got, ["holdBegan", "holdInterrupted"])
    }

    /// Utter's own paste doesn't break a double tap starting either.
    func testUttersOwnPasteBetweenTheTwoTapsOfADoubleTap() {
        let tap = HotkeyTap()
        var now: UInt64 = 0
        tap.currentFlags = { now }
        tap.configure([(.auto, .modifier(.fn))])
        var got: [String] = []
        tap.onTrigger = { got.append("\($0.kind)") }
        now = fn; flags(tap, 63, fn); wait(0.08); now = 0; flags(tap, 63, 0)
        let v = Paster.commandV()!
        _ = tap.handle(.keyDown, v.down); _ = tap.handle(.keyUp, v.up)
        wait(0.05)
        now = fn; flags(tap, 63, fn); wait(0.08); now = 0; flags(tap, 63, 0)
        wait(0.1)
        XCTAssertEqual(got, ["finish", "handsFree"])
    }
}

final class MicFeedTests: XCTestCase {
    /// Audio heard between key-down and the start of the dictation comes first, then the rest in order.
    func testEarlyAudioIsHandedOnFirstThenLiveAudio() {
        let feed = MicFeed()
        feed.push([1, 2]); feed.push([3])
        var got: [Int16] = []
        XCTAssertEqual(feed.attach { got += $0 }, 3)
        feed.push([4, 5])
        XCTAssertEqual(got, [1, 2, 3, 4, 5])
    }

    func testOnlyTheLastSecondIsKeptBeforeADictationStarts() {
        let feed = MicFeed()
        feed.push([Int16](repeating: 7, count: MicFeed.keep))
        feed.push([Int16](repeating: 9, count: 100))
        var got: [Int16] = []
        XCTAssertEqual(feed.attach { got += $0 }, MicFeed.keep)
        XCTAssertEqual(got.suffix(100), [Int16](repeating: 9, count: 100)[...])
    }
}

final class FocusTests: XCTestCase {
    func testFocusComparison() {
        let a = Paster.Focus(pid: 10, element: nil, role: "AXTextArea", frame: CGRect(x: 0, y: 0, width: 50, height: 20), kind: .text)
        var b = a
        XCTAssertTrue(a.isSame(as: b))
        b.pid = 11
        XCTAssertFalse(a.isSame(as: b), "another app")
        let x = AXUIElementCreateApplication(10), y = AXUIElementCreateApplication(12)
        var c = a; c.element = x
        var d = a; d.element = y
        XCTAssertTrue(c.isSame(as: c))
        XCTAssertTrue(c.isSame(as: d), "a new reference to an element of the same role in the same place")
        d.frame = CGRect(x: 0, y: 100, width: 50, height: 20)
        XCTAssertFalse(c.isSame(as: d), "another field in the same app")
    }
}

/// The pill, off screen, stepped by hand at 60 fps.
final class HUDTests: XCTestCase {
    private func run(_ hud: HUD, _ seconds: Double) { for _ in 0..<Int(seconds * 60) { hud.advance(1 / 60) } }

    func testThePillSettlesInEachStateAndGoesAway() {
        let hud = HUD(onScreen: false)
        hud.set(.listening)
        run(hud, 1)
        XCTAssertEqual(hud.pillSize.width, hud.pillTargetWidth, accuracy: 0.5)
        XCTAssertEqual(hud.pillSize.height, HUD.height, accuracy: 0.5)
        XCTAssertEqual(hud.pillOpacity, 1, accuracy: 0.01)
        let listening = hud.pillSize.width
        hud.set(.handsFree)
        run(hud, 1)
        XCTAssertEqual(hud.pillSize.width, listening + HUD.lockRoom, accuracy: 0.5, "room for the lock")
        hud.set(.notice(.copied))
        run(hud, 1)
        XCTAssertEqual(hud.pillSize.width, HUD.noticeWidth, accuracy: 0.5)
        hud.set(.hidden)
        run(hud, 1)
        XCTAssertLessThan(hud.pillOpacity, 0.01)
    }

    /// Springy but restrained: no size swings more than a few percent past where it's going, at any frame rate.
    func testSpringsBarelyPassTheirTarget() {
        for fps in [30.0, 60, 120] {
            var s = Spring(32, response: 0.42, bounce: 0.22)
            s.target = 81
            var most: CGFloat = 0
            for _ in 0..<Int(fps * 2) { s.step(CGFloat(1 / fps)); most = max(most, s.value) }
            XCTAssertLessThan((most - 81) / (81 - 32), 0.04, "at \(fps) fps")
            XCTAssertEqual(s.value, 81, accuracy: 0.05, "settled at \(fps) fps")
        }
    }
}
