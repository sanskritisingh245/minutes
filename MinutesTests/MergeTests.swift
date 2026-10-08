import XCTest
@testable import Minutes

final class MergeTests: XCTestCase {
    func testAssignsSpeakersSmoothsIslandsAndOrdersByFirstAppearance() {
        func w(_ t: String, _ s: Double) -> Word { Word(text: t, start: s, end: s + 0.4) }
        let words = [w("Hi", 0), w("there.", 0.5), w("Hello!", 2.0), w("How", 2.5), w("are", 3.0),
                     w("uh", 3.5), w("you?", 4.0), w("Great.", 6.1)]
        let segments = [
            Merge.Segment(speaker: "S7", start: 0, end: 1.0),   // first voice → Speaker 1
            Merge.Segment(speaker: "S3", start: 1.9, end: 3.4),
            Merge.Segment(speaker: "S7", start: 3.4, end: 3.95), // 1-word island inside S3 → absorbed
            Merge.Segment(speaker: "S3", start: 4.0, end: 4.5),
            Merge.Segment(speaker: "S7", start: 6.5, end: 7.0),  // "Great." has no overlap → nearest
        ]
        let turns = Merge.turns(words: words, segments: segments)
        XCTAssertEqual(turns.map(\.speaker), [0, 1, 0])
        XCTAssertEqual(turns.map(\.text), ["Hi there.", "Hello! How are uh you?", "Great."])
        XCTAssertEqual(turns[1].start, 2.0)
        XCTAssertTrue(Merge.turns(words: [], segments: segments).isEmpty)
    }

    /// Real iPhone data: both engines stretch a word across the pause between speakers, in opposite directions.
    func testWordsStretchedOverPausesKeepTheirSpeaker() {
        let segments = [Merge.Segment(speaker: "A", start: 31.3, end: 37.24), Merge.Segment(speaker: "B", start: 37.84, end: 42.27)]
        // Apple: first word after the pause reaches back ("Great." 36.78–38.04); Transcriber trims it.
        let apple = [Word(text: "Friday.", start: 36.36, end: 36.72), Word(text: "Great.", start: 36.78, end: 38.04),
                     Word(text: "I'll", start: 38.16, end: 38.82)].map(Transcriber.trimmed)
        XCTAssertEqual(Merge.turns(words: apple, segments: segments).map(\.text), ["Friday.", "Great. I'll"])
        // Parakeet: last word before the pause reaches forward ("Friday." 36.64–37.76); plain overlap handles it.
        let parakeet = [Word(text: "next", start: 36.40, end: 36.64), Word(text: "Friday.", start: 36.64, end: 37.76),
                        Word(text: "Great,", start: 37.76, end: 38.40)]
        XCTAssertEqual(Merge.turns(words: parakeet, segments: segments).map(\.text), ["next Friday.", "Great,"])
    }
}
