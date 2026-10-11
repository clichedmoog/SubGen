import Foundation

enum AudioPreparation {
    struct Chunk: Equatable {
        let start: Double
        let duration: Double
    }

    static func chunks(duration: Double, size: Double = 1800) -> [Chunk] {
        guard duration.isFinite, duration > 0, size.isFinite, size > 0 else { return [] }
        return (0..<Int(ceil(duration / size))).map {
            let start = Double($0) * size
            return Chunk(start: start, duration: min(size, duration - start))
        }
    }

    static func samples(duration: Double) -> [Chunk] {
        guard duration.isFinite, duration > 0 else { return [] }
        if duration <= 30 { return [Chunk(start: 0, duration: duration)] }
        return [0.10, 0.50, 0.90, 0.30, 0.70, 0.20, 0.40, 0.60].map {
            let start = min(duration * $0, max(0, duration - 5))
            return Chunk(start: start, duration: min(30, duration - start))
        }
    }

    static func detectLanguage(_ output: String) -> (language: String, probability: Double)? {
        let pattern = #"auto-detected language: ([a-z]{2,3}) \(p = ([0-9.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let language = Range(match.range(at: 1), in: output),
              let confidence = Range(match.range(at: 2), in: output),
              let probability = Double(output[confidence]), probability.isFinite, (0...1).contains(probability) else { return nil }
        return (String(output[language]), probability)
    }

    /// Speech intervals whisper.cpp logs after VAD filtering, in seconds from the chunk start.
    static func speechSegments(in output: String) -> [ClosedRange<Double>] {
        let pattern = #"^whisper_vad_segments_from_probs: VAD segment \d+: start = (\d+(?:\.\d+)?), end = (\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match in
            guard let start = Range(match.range(at: 1), in: output).flatMap({ Double(output[$0]) }),
                  let end = Range(match.range(at: 2), in: output).flatMap({ Double(output[$0]) }),
                  start.isFinite, end.isFinite, end > start else { return nil }
            return start...end
        }
    }

    static func extract(source: URL, chunk: Chunk, destination: URL, ffmpeg: String, cancellation: CancellationToken) -> ProcessResult {
        ProcessRunner.run(ffmpeg, arguments: ["-nostdin", "-v", "error", "-y", "-ss", String(chunk.start), "-i", source.path,
            "-t", String(chunk.duration), "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", destination.path],
            timeout: max(120, chunk.duration), cancellation: cancellation)
    }

    static func transcriptionPosition(in line: String, chunk: Chunk) -> (seconds: Double, estimated: Bool)? {
        guard chunk.duration.isFinite, chunk.duration > 0 else { return nil }
        if let range = line.range(of: #"\d{2,}:[0-5]\d:[0-5]\d\.\d{3}\]"#, options: .regularExpression),
           let end = SrtDocument.timestamp(String(line[range].dropLast()).replacingOccurrences(of: ".", with: ",")) {
            return (chunk.start + min(end, chunk.duration), false)
        }
        let pattern = #"^whisper_print_progress_callback:\s+progress\s*=\s*(\d{1,3})%\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line), let percent = Double(line[range]), (0...100).contains(percent) else { return nil }
        // This is decoder progress mapped to audio time, especially approximate
        // when VAD removes silence. Reserve completion for output validation.
        return (chunk.start + chunk.duration * min(percent, 99) / 100, true)
    }
}
