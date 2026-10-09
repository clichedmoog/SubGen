import Foundation

struct SrtDocument {
    struct Cue: Equatable {
        var number: Int
        var start: Double
        var end: Double
        var text: String
    }
    enum Invalid: Error { case malformed }
    var cues: [Cue]

    init(_ content: String) throws {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw Invalid.malformed }
        let separated = normalized.replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\n\n", options: .regularExpression)
        var parsed: [Cue] = []
        for block in separated.components(separatedBy: "\n\n").filter({ !$0.isEmpty }) {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3, let number = Int(lines[0].trimmingCharacters(in: .whitespaces)), number > 0 else { throw Invalid.malformed }
            let times = lines[1].components(separatedBy: " --> ")
            guard times.count == 2, let start = Self.timestamp(times[0]), let end = Self.timestamp(times[1]), end > start else { throw Invalid.malformed }
            let text = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, parsed.last.map({ number > $0.number && start >= $0.start }) ?? true else { throw Invalid.malformed }
            parsed.append(Cue(number: number, start: start, end: end, text: text))
        }
        guard !parsed.isEmpty else { throw Invalid.malformed }
        cues = parsed
    }

    init(cues: [Cue]) { self.cues = cues }

    static func timestamp(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^\d{2,}:[0-5]\d:[0-5]\d,\d{3}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        let value = hours * 3600 + minutes * 60 + seconds
        return value.isFinite && value < Double(Int.max / 1000 - 1) ? value : nil
    }

    func matchesTiming(of source: SrtDocument) -> Bool {
        cues.count == source.cues.count && zip(cues, source.cues).allSatisfy {
            $0.number == $1.number && abs($0.start - $1.start) < 0.0001 && abs($0.end - $1.end) < 0.0001
        }
    }

    func shifted(by offset: Double) -> SrtDocument {
        SrtDocument(cues: cues.map { Cue(number: $0.number, start: $0.start + offset, end: $0.end + offset, text: $0.text) })
    }

    func render(renumber: Bool = false) -> String {
        cues.enumerated().map { index, cue in
            "\(renumber ? index + 1 : cue.number)\n\(Self.format(cue.start)) --> \(Self.format(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func format(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
