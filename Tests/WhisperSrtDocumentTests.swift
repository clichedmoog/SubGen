import XCTest
@testable import SubtitleGen

final class WhisperSrtDocumentTests: XCTestCase {
    func testWhisperBlankAndZeroDurationSegmentsDoNotInvalidateGoodCues() throws {
        let raw = """
        1
        00:00:00,000 --> 00:00:00,000
        Zero duration.

        2
        00:00:00,000 --> 00:00:01,000
          

        3
        00:00:01,000 --> 00:00:03,000
        Valid dialogue.
        """
        XCTAssertThrowsError(try SrtDocument(raw), "Previously the whole recognizer result was rejected")
        let recognized = try WhisperSrtDocument(raw, duration: 3)
        XCTAssertEqual(recognized.omittedCount, 2)
        let source = try SrtDocument(SrtDocument(cues: recognized.cues).render())
        XCTAssertEqual(source.cues, [.init(number: 1, start: 1, end: 3, text: "Valid dialogue.")])
    }
    func testRecognizerTimingsAreSortedClippedAndRenumberedBeforeTranslation() throws {
        let raw = "1\n00:00:02,000 --> 00:00:04,000\nLater.\n\n2\n00:00:01,000 --> 00:00:02,000\nEarlier.\n\n3\n00:00:03,000 --> 00:00:04,000\nOutside chunk.\n"
        let recognized = try WhisperSrtDocument(raw, duration: 3)
        let source = try SrtDocument(SrtDocument(cues: recognized.cues).render())
        XCTAssertEqual(source.cues.map(\.number), [1, 2]); XCTAssertEqual(source.cues.map(\.start), [1, 2])
        XCTAssertEqual(source.cues.last?.end, 3); XCTAssertEqual(recognized.omittedCount, 1)
        XCTAssertTrue(source.matchesTiming(of: try SrtDocument(source.render())))
    }
    func testGenuinelyMalformedRecognizerOutputStillFailsWithCueNumber() {
        for raw in ["1\ninvalid --> 00:00:01,000\nText.", "1\n00:00:02,000 --> 00:00:01,000\nText."] {
            XCTAssertThrowsError(try WhisperSrtDocument(raw, duration: 3)) { error in
                XCTAssertTrue(error.localizedDescription.contains("1번")); XCTAssertFalse(error.localizedDescription.contains("Text."))
            }
        }
    }
    func testEmptyRecognizerOutputDoesNotInventSubtitles() throws {
        XCTAssertTrue(try WhisperSrtDocument("", duration: 3).cues.isEmpty)
        XCTAssertTrue(try WhisperSrtDocument("1\n00:00:00,000 --> 00:00:00,000\nSilent.", duration: 3).cues.isEmpty)
    }
}
