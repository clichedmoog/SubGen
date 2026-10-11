import Foundation

/// Framework-independent parts of Apple Translation support. Subtitle numbers and timings
/// are copied from the source and never pass through the translator.
enum AppleTranslationMapping {
    struct Missing: LocalizedError {
        let cue: Int
        var errorDescription: String? { "Apple 번역 결과에 \(cue)번 자막이 없습니다." }
    }

    /// Whisper/SRT two-letter codes to identifiers understood by the Translation framework.
    static func languageIdentifier(for code: String) -> String? {
        let code = code.lowercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code == "zh" ? "zh-Hans" : code
    }

    static func requests(for document: SrtDocument) -> [(id: String, text: String)] {
        document.cues.map { (String($0.number), singleLine($0.text)) }
    }

    static func assemble(_ document: SrtDocument, translations: [String: String]) throws -> SrtDocument {
        SrtDocument(cues: try document.cues.map { cue in
            let text = singleLine(translations[String(cue.number)] ?? "")
            guard !text.isEmpty else { throw Missing(cue: cue.number) }
            return SrtDocument.Cue(number: cue.number, start: cue.start, end: cue.end, text: text)
        })
    }

    /// Display line breaks are not meaningful to the translator, and a blank line would split an SRT block.
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
