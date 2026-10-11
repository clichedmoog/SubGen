import Foundation

/// Normalize recognizer output before it becomes our validated source SRT.
/// User-provided SRTs and translations still use strict SrtDocument parsing.
struct WhisperSrtDocument {
    struct Invalid: LocalizedError {
        let cue: Int
        let reason: String
        var errorDescription: String? { "전사 자막 \(cue)번: \(reason)" }
    }
    let cues: [SrtDocument.Cue]
    let omittedCount: Int

    init(_ content: String, duration: Double) throws {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let separated = normalized.replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\n\n", options: .regularExpression)
        var parsed: [SrtDocument.Cue] = []
        var previousNumber = 0, omitted = 0
        for (index, block) in separated.components(separatedBy: "\n\n").enumerated() {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let lines = trimmed.components(separatedBy: "\n")
            guard lines.count >= 2, let number = Int(lines[0].trimmingCharacters(in: .whitespaces)), number > previousNumber else {
                throw Invalid(cue: index + 1, reason: "번호 또는 시간 행이 올바르지 않습니다.")
            }
            previousNumber = number
            let times = lines[1].components(separatedBy: " --> ")
            guard times.count == 2, let start = SrtDocument.timestamp(times[0]), let end = SrtDocument.timestamp(times[1]), end >= start else {
                throw Invalid(cue: number, reason: "시작·종료 시간이 올바르지 않습니다.")
            }
            let text = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let clippedEnd = min(end, duration)
            // whisper.cpp writes all segments, including blank/zero-duration
            // ones which have no display interval and cannot form valid SRT.
            guard !text.isEmpty, clippedEnd > start else { omitted += 1; continue }
            parsed.append(.init(number: number, start: start, end: clippedEnd, text: text))
        }
        cues = parsed.sorted { $0.start == $1.start ? $0.number < $1.number : $0.start < $1.start }
            .enumerated().map { index, cue in
                .init(number: index + 1, start: cue.start, end: cue.end, text: cue.text)
            }
        omittedCount = omitted
    }

    /// whisper.cpp maps a segment that spans several VAD regions back across the silence
    /// between them, so a cue can start long before its speech. Clip each cue to the speech
    /// it overlaps while keeping it readable within its recognized interval.
    static func trim(_ cues: [SrtDocument.Cue], toSpeech speech: [ClosedRange<Double>],
                     minimumDuration: Double = 1) -> [SrtDocument.Cue] {
        cues.map { cue in
            let overlapping = speech.filter { min(cue.end, $0.upperBound) > max(cue.start, $0.lowerBound) }
            guard let first = overlapping.map(\.lowerBound).min(), let last = overlapping.map(\.upperBound).max() else { return cue }
            var start = max(cue.start, first), end = min(cue.end, last)
            let minimum = min(minimumDuration, cue.end - cue.start)
            if end - start < minimum { end = min(cue.end, start + minimum); start = end - minimum }
            return .init(number: cue.number, start: start, end: end, text: cue.text)
        }
    }
}
