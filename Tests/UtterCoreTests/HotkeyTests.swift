import XCTest
@testable import UtterCore

final class HotkeyTests: XCTestCase {
    private let opt = UInt64(0x80000), cmd = UInt64(0x100000), shift = UInt64(0x20000)

    func testSidesAndAlone() {
        let leftOpt = opt | 0x20, rightCmd = cmd | 0x10
        XCTAssertTrue(ModifierKey.option.isDown(leftOpt))
        XCTAssertTrue(ModifierKey.leftOption.isDown(leftOpt))
        XCTAssertFalse(ModifierKey.rightOption.isDown(leftOpt))
        XCTAssertTrue(ModifierKey.rightCommand.isDown(rightCmd))
        XCTAssertTrue(ModifierKey.rightCommand.isAlone(rightCmd))
        XCTAssertFalse(ModifierKey.rightCommand.isAlone(rightCmd | 0x8))      // left ⌘ held too
        XCTAssertFalse(ModifierKey.option.isAlone(leftOpt | shift))
        XCTAssertTrue(ModifierKey.option.isAlone(leftOpt | 0x10000))          // caps lock doesn't count
        XCTAssertTrue(ModifierKey.fn.isDown(0x800000))
    }

    func testCodableRoundTrip() throws {
        for h: Hotkey in [.modifier(.rightCommand), .combo(keyCode: 49, modifiers: opt | cmd, key: "Space")] {
            XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(h)), h)
        }
    }

    func testTitles() {
        XCTAssertEqual(Hotkey.modifier(.option).title(handsFree: true), "Double-tap ⌥ Option")
        XCTAssertEqual(Hotkey.combo(keyCode: 49, modifiers: opt | 0x40000, key: "Space").title(handsFree: false), "⌃⌥Space")
    }

    func testClashes() {
        let option = Hotkey.modifier(.option)
        XCTAssertEqual(Hotkey.clashes([("Auto's key", option), ("Instant's key", nil)]), [])
        // The user's setup: Auto on ⌥ (either side), Thorough on left ⌥: not a clash, the one side wins it, and a note says so.
        let named: [(name: String, hotkey: Hotkey?)] = [("Auto's key", option), ("Instant's key", .modifier(.fn)),
                                                        ("Balanced's key", .modifier(.leftControl)), ("Thorough's key", .modifier(.leftOption))]
        XCTAssertEqual(Hotkey.clashes(named), [])
        XCTAssertEqual(Hotkey.sideNotes(named), ["Left ⌥ Option is Thorough's key; Right ⌥ Option stays with Auto's key."])
        // Two modes on the same key: a clash, and only the first works.
        XCTAssertEqual(Hotkey.clashes([("Auto's key", option), ("Instant's key", option)]),
                       ["Auto's key and Instant's key are both ⌥ Option: only Auto's key works."])
        XCTAssertEqual(Hotkey.clashes([("A", .modifier(.leftOption)), ("B", .modifier(.leftOption))]).count, 1)
        let combo = Hotkey.combo(keyCode: 2, modifiers: opt | 0x40000, key: "D")
        XCTAssertEqual(Hotkey.clashes([("Auto's key", combo), ("Balanced's key", combo)]).count, 1)
    }

    func testComboRules() {
        XCTAssertNotNil(Hotkey.problem(keyCode: 0, modifiers: shift))   // ⇧A would break typing
        XCTAssertNil(Hotkey.problem(keyCode: 0, modifiers: opt))
        XCTAssertNil(Hotkey.problem(keyCode: 105, modifiers: 0))        // F13 alone is fine
        XCTAssertNotNil(Hotkey.combo(keyCode: 49, modifiers: cmd, key: "Space").systemConflict)
    }

    // The recorder: modifiers come in as (key code, flags after the change).
    private let fnF: UInt64 = 0x800000, sh: UInt64 = 0x20000

    private func record(_ steps: [(Int, UInt64)]) -> HotkeyRecording.Outcome? {
        var r = HotkeyRecording()
        var out: HotkeyRecording.Outcome?
        for (code, flags) in steps { if let o = r.flagsChanged(keyCode: code, flags: flags) { out = o } }
        return out
    }

    func testRecordsFnShiftChordEitherOrderAndRelease() {
        let fnShift = Hotkey.chord(modifiers: fnF | sh)
        XCTAssertEqual(record([(63, fnF), (56, fnF | sh | 0x2), (56, fnF), (63, 0)]), .hotkey(fnShift))
        XCTAssertEqual(record([(56, sh | 0x2), (63, fnF | sh | 0x2), (63, sh | 0x2), (56, 0)]), .hotkey(fnShift))
        XCTAssertEqual(fnShift.title(handsFree: false), "fn ⇧")
    }

    func testRecordsShiftCommandChord() {
        XCTAssertEqual(record([(56, sh | 0x2), (55, sh | 0x2 | cmd | 0x8), (55, sh | 0x2), (56, 0)]), .hotkey(.chord(modifiers: sh | cmd)))
        XCTAssertEqual(Hotkey.chord(modifiers: sh | cmd).title(handsFree: false), "⇧⌘")
    }

    func testSingleModifiersKeepTheirSide() {
        XCTAssertEqual(record([(58, opt | 0x20), (58, 0)]), .hotkey(.modifier(.leftOption)))
        XCTAssertEqual(record([(63, fnF), (63, 0)]), .hotkey(.modifier(.fn)))
    }

    func testShortcutWithAKeyIsAComboNotAChord() {
        var r = HotkeyRecording()
        _ = r.flagsChanged(keyCode: 56, flags: sh | 0x2)
        _ = r.flagsChanged(keyCode: 55, flags: sh | 0x2 | cmd | 0x8)
        XCTAssertEqual(r.keyDown(keyCode: 21, flags: sh | cmd, label: "4"), .hotkey(.combo(keyCode: 21, modifiers: sh | cmd, key: "4")))
        XCTAssertNil(r.flagsChanged(keyCode: 55, flags: sh | 0x2))
        XCTAssertNil(r.flagsChanged(keyCode: 56, flags: 0))
        // fn with a letter isn't allowed (it would type), and Esc keeps the old key.
        var r2 = HotkeyRecording()
        if case .problem = r2.keyDown(keyCode: 0, flags: fnF, label: "A") {} else { XCTFail("fn+A should be refused") }
        XCTAssertEqual(r2.keyDown(keyCode: 53, flags: 0, label: "Esc"), .cancel)
    }

    func testChordClashes() {
        let a = Hotkey.chord(modifiers: fnF | sh)
        XCTAssertTrue(a.overlaps(.chord(modifiers: sh | fnF)))
        XCTAssertFalse(a.overlaps(.modifier(.fn)))   // fn alone and fn ⇧ are different keys
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(a)), a)
    }
}
