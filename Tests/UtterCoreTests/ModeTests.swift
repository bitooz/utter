import XCTest
@testable import UtterCore

final class ModeTests: XCTestCase {
    func testAutoPicksByLength() {
        XCTAssertEqual(Mode.auto.tier(forSeconds: 5, autoAfter: 20), .fast)
        XCTAssertEqual(Mode.auto.tier(forSeconds: 20, autoAfter: 20), .accurate)
        XCTAssertEqual(Mode.veryAccurate.tier(forSeconds: 2, autoAfter: 20), .veryAccurate)
    }

    func testDefaultsAndCustomModels() {
        let set = ModelSet()
        XCTAssertEqual(set.fast.id, "google/gemini-3.1-flash-lite")
        XCTAssertEqual(set.accurate.id, "google/gemini-3.8-flash")
        XCTAssertEqual(set.veryAccurate.id, "google/gemini-4-argon")
        XCTAssertNotNil(Model.lite.routes)
        let custom = Model(" openai/gpt-audio-mini ")
        XCTAssertEqual(custom.id, "openai/gpt-audio-mini")
        XCTAssertNil(custom.routes)                     // routing left to OpenRouter
        XCTAssertEqual(custom.name, "gpt-audio-mini")   // until the model list names it
    }

    func testPromptCarriesVocabularyAfterCustomPrompt() {
        let t = Transcriber(key: "x")
        t.systemPrompt = "Write it all in lowercase."
        t.vocabulary = ["Utter"]
        let p = t.systemPrompt(context: nil, overlaps: false)
        XCTAssertTrue(p.hasPrefix("Write it all in lowercase."))
        XCTAssertTrue(p.contains("required spellings: Utter"))
    }

    func testKeyShape() {
        XCTAssertTrue(KeyStore.looksValid("sk-or-v1-0123456789abcdef0123"))
        XCTAssertFalse(KeyStore.looksValid("sk-or-v1-abc 123; rm -rf"))
        XCTAssertEqual(KeyStore.masked("sk-or-v1-0123456789abcdef3f9a"), "sk-or-v1-…3f9a")
    }

    func testVocabularyAddAndRemoveKeepNotes() {
        let text = "# my words\nFilo\nUtter\n"
        let added = Vocabulary.adding("Retype, utter, Claude Code", to: text)
        XCTAssertEqual(Vocabulary.parse(added), ["Filo", "Utter", "Retype", "Claude Code"])   // "utter" was already there
        let removed = Vocabulary.removing("filo", from: added)
        XCTAssertEqual(Vocabulary.parse(removed), ["Utter", "Retype", "Claude Code"])
        XCTAssertTrue(removed.hasPrefix("# my words"))
    }

    func testPromptPreviewIsWhatIsSent() {
        let t = Transcriber(key: "x")
        t.systemPrompt = "Be brief."
        t.vocabulary = ["Filo"]
        let p = t.systemPrompt(context: nil, overlaps: false)
        XCTAssertTrue(p.hasPrefix("Be brief.") && p.contains("Filo"))
    }
}
