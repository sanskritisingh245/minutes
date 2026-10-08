import XCTest
@testable import Minutes

final class NotesParseTests: XCTestCase {
    func testParsesSectionsOwnersAndStripsThinking() {
        let raw = """
        <think>
        </think>
        # Q3 Launch Sync
        ## Summary
        The team agreed to ship on Friday.
        Marketing needs final copy.
        ## Key Decisions
        - Ship v2 on Friday
        * Drop the beta flag
        ## Action Items
        - [Speaker 2] Send final copy
        - [Unassigned] Book the venue
        1. Update the changelog
        """
        let out = NotesWriter.parse(raw)
        XCTAssertEqual(out.title, "Q3 Launch Sync")
        XCTAssertEqual(out.notes.summary, "The team agreed to ship on Friday. Marketing needs final copy.")
        XCTAssertEqual(out.notes.decisions, ["Ship v2 on Friday", "Drop the beta flag"])
        XCTAssertEqual(out.notes.actions.map(\.text), ["Send final copy", "Book the venue", "Update the changelog"])
        XCTAssertEqual(out.notes.actions.map(\.owner), ["Speaker 2", nil, nil])
        XCTAssertEqual(NotesWriter.parse("Just prose.").notes.summary, "Just prose.") // format ignored → nothing lost
    }
}
