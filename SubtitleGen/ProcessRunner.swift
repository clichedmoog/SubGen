import Foundation
import Darwin

/// One token owns all processes for a file, including parallel translations.
final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [UUID: Process] = [:]

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = Array(processes.values)
        lock.unlock()
        running.forEach { ProcessRunner.stop($0, force: false) }
    }

    func register(_ process: Process) -> UUID {
        let id = UUID()
        lock.lock()
        processes[id] = process
        let shouldStop = cancelled
        lock.unlock()
        if shouldStop { ProcessRunner.stop(process, force: false) }
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes.removeValue(forKey: id)
    }
}

struct ProcessResult {
    enum Failure: Equatable {
        case launch(String), cancelled, timedOut, service(String, retryable: Bool)
    }
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32 = -1
    var failure: Failure?
    var succeeded: Bool { failure == nil && exitCode == 0 }
    var output: String { stdout + "\n" + stderr }
    var diagnostic: String {
        switch failure {
        case .launch(let message): return message
        case .service(let message, _): return message
        case .cancelled: return "작업이 중단되었습니다"
        case .timedOut: return "실행 제한 시간을 초과했습니다"
        case nil:
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "종료 코드 \(exitCode): \(detail.suffix(1200))"
        }
    }
}

enum ProcessRunner {
    private final class Capture {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        // Keep memory bounded even if a failed CLI prints endlessly.
        let limit = 16 * 1024 * 1024
        func append(_ data: Data, isError: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isError {
                stderr.append(data)
                if stderr.count > limit { stderr.removeFirst(stderr.count - limit) }
            } else {
                stdout.append(data)
                if stdout.count > limit { stdout.removeFirst(stdout.count - limit) }
            }
        }
    }

    static func stop(_ process: Process, force: Bool) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let signal = force ? SIGKILL : SIGTERM
        // Foundation normally creates a separate process group. Include CLI
        // children, but never signal our own application's group.
        if getpgid(pid) == pid && pid != getpgrp() {
            Darwin.kill(-pid, signal)
        } else {
            Darwin.kill(pid, signal)
        }
    }

    static func run(
        _ executable: String,
        arguments: [String],
        input: String? = nil,
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval = 3600,
        cancellation: CancellationToken? = nil,
        onOutput: ((String) -> Void)? = nil
    ) -> ProcessResult {
        if cancellation?.isCancelled == true { return ProcessResult(failure: .cancelled) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input == nil ? nil : Pipe()
        if let stdin {
            process.standardInput = stdin
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        } else { process.standardInput = FileHandle.nullDevice }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return ProcessResult(failure: .launch(error.localizedDescription)) }
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid && pid != getpgrp()
        // The parent must not retain the child's read end if it exits before
        // consuming a large prompt.
        try? stdin?.fileHandleForReading.close()

        let registration = cancellation?.register(process)
        defer { if let registration { cancellation?.unregister(registration) } }
        let capture = Capture()
        let readers = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                var pending = Data()
                while let data = try? pipe.fileHandleForReading.read(upToCount: 16384), !data.isEmpty {
                    capture.append(data, isError: isError)
                    if let onOutput {
                        pending.append(data)
                        // Deliver complete UTF-8 lines; timestamps can span reads.
                        while let newline = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                            let line = pending.prefix(through: newline)
                            onOutput(String(decoding: line, as: UTF8.self))
                            pending.removeFirst(line.count)
                        }
                        if pending.count > 65536 {
                            onOutput(String(decoding: pending, as: UTF8.self))
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !pending.isEmpty { onOutput?(String(decoding: pending, as: UTF8.self)) }
            }
        }
        if let input, let stdin {
            DispatchQueue.global(qos: .utility).async {
                defer { try? stdin.fileHandleForWriting.close() }
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var failure: ProcessResult.Failure?
        while exited.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation?.isCancelled == true { failure = .cancelled; break }
            if Date() >= deadline { failure = .timedOut; break }
        }
        if failure != nil {
            stop(process, force: false)
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                stop(process, force: true)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        if cancellation?.isCancelled == true { failure = .cancelled }
        if failure != nil, ownsGroup { Darwin.kill(-pid, SIGKILL) }
        if readers.wait(timeout: .now() + 2) == .timedOut {
            if ownsGroup { Darwin.kill(-pid, SIGKILL) }
            _ = readers.wait(timeout: .now() + 2)
            failure = failure ?? .timedOut
        }
        capture.lock.lock(); defer { capture.lock.unlock() }
        return ProcessResult(
            stdout: String(decoding: capture.stdout, as: UTF8.self),
            stderr: String(decoding: capture.stderr, as: UTF8.self),
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            failure: failure
        )
    }
}
