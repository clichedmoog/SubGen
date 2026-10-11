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
    func testWhisperVadLogReportsSpeechSegmentsInChunkTime() {
        // whisper.cpp 1.8.4 stderr after --vad.
        let log = """
        whisper_vad_segments_from_probs: Merged 20 adjacent segments, now have 3 segments
        whisper_vad_segments_from_probs: Final speech segments after filtering: 3
        whisper_vad_segments_from_probs: VAD segment 0: start = 11.59, end = 12.41 (duration: 0.82)
        whisper_vad_segments_from_probs: VAD segment 1: start = 12.58, end = 15.13 (duration: 2.55)
        whisper_vad_segments_from_probs: VAD segment 2: start = 687.81, end = 688.10 (duration: 0.29)
        [00:00:11.590 --> 00:00:14.880]  VAD segment 9: start = 1.0, end = 2.0 is dialogue, not a log line
        """
        XCTAssertEqual(AudioPreparation.speechSegments(in: log), [11.59...12.41, 12.58...15.13, 687.81...688.10])
        XCTAssertEqual(AudioPreparation.speechSegments(in: "whisper_full: no VAD"), [])
    }
    func testCuesStartWhenSpeechStartsAndStayReadable() {
        let speech: [ClosedRange<Double>] = [11.59...12.41, 12.58...15.13, 40...42, 687.81...688.10]
        let cues: [SrtDocument.Cue] = [
            .init(number: 1, start: 0, end: 14.88, text: "Long ago, there was a small kingdom."),
            .init(number: 2, start: 14.88, end: 22.08, text: "Ends after speech."),
            .init(number: 3, start: 30, end: 35, text: "No detected speech."),
            .init(number: 4, start: 595.49, end: 688.10, text: "No."),
            .init(number: 5, start: 41, end: 41.4, text: "Short.")
        ]
        let trimmed = WhisperSrtDocument.trim(cues, toSpeech: speech)
        let milliseconds = { (value: Double) in (value * 1000).rounded() / 1000 }
        XCTAssertEqual(trimmed.map { milliseconds($0.start) }, [11.59, 14.88, 30, 687.1, 41])
        XCTAssertEqual(trimmed.map { milliseconds($0.end) }, [14.88, 15.88, 35, 688.1, 41.4])
        XCTAssertEqual(trimmed.map(\.text), cues.map(\.text)); XCTAssertEqual(trimmed.map(\.number), [1, 2, 3, 4, 5])
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
