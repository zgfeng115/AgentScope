import Foundation

public struct CommandRunner: Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 30,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: executable.path) else {
            throw CommandRunnerError.executableNotFound(path: executable.path)
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CommandRunnerError.permissionDenied(path: executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        let state = ExecutionState()
        let stdoutCollector = PipeOutputCollector()
        let stderrCollector = PipeOutputCollector()
        let outputGroup = DispatchGroup()

        // Incremental reads: a grandchild that inherited the pipe must not keep us waiting for EOF forever.
        func drain(_ pipe: Pipe, into collector: PipeOutputCollector) {
            outputGroup.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if collector.markFinished() { outputGroup.leave() }
                } else {
                    collector.append(chunk)
                }
            }
        }

        @Sendable func stopDraining() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        @Sendable func partialResult(exitCode: Int32, timedOut: Bool) -> CommandResult {
            CommandResult(
                stdout: Self.string(from: stdoutCollector.data),
                stderr: Self.string(from: stderrCollector.data),
                exitCode: exitCode,
                timedOut: timedOut,
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let status = process.terminationStatus
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = outputGroup.wait(timeout: .now() + Self.outputGrace)
                    stopDraining()
                    let result = partialResult(exitCode: status, timedOut: state.hasTimedOut)
                    if result.timedOut {
                        state.resumeFailure(CommandRunnerError.timedOut(result), continuation: continuation)
                    } else if result.exitCode != 0 {
                        state.resumeFailure(CommandRunnerError.nonZeroExit(result), continuation: continuation)
                    } else {
                        state.resumeSuccess(result, continuation: continuation)
                    }
                }
            }

            drain(stdoutPipe, into: stdoutCollector)
            drain(stderrPipe, into: stderrCollector)

            do {
                try process.run()
            } catch {
                stopDraining()
                let path = executable.path
                if (error as NSError).code == CocoaError.fileNoSuchFile.rawValue {
                    state.resumeFailure(CommandRunnerError.executableNotFound(path: path), continuation: continuation)
                } else {
                    state.resumeFailure(CommandRunnerError.permissionDenied(path: path), continuation: continuation)
                }
                return
            }

            let pid = process.processIdentifier
            let effectiveTimeout = max(timeout, 0.001)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + effectiveTimeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                // Give up waiting now: a child stuck in the kernel may never exit. Its exit status is unknown.
                state.resumeFailure(
                    CommandRunnerError.timedOut(partialResult(exitCode: Self.unknownExitCode, timedOut: true)),
                    continuation: continuation
                )
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.killGrace) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    static let unknownExitCode: Int32 = -1
    private static let killGrace: TimeInterval = 1
    private static let outputGrace: TimeInterval = 2

    private static func string(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

private final class PipeOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private var finished = false

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    /// True only for the first EOF, so the output group is left exactly once.
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var timedOut = false

    var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func resumeSuccess<T: Sendable>(
        _ value: T,
        continuation: CheckedContinuation<T, Error>
    ) {
        guard claimContinuation() else { return }
        continuation.resume(returning: value)
    }

    func resumeFailure<T: Sendable>(
        _ error: Error,
        continuation: CheckedContinuation<T, Error>
    ) {
        guard claimContinuation() else { return }
        continuation.resume(throwing: error)
    }

    private func claimContinuation() -> Bool {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return false
        }
        hasResumed = true
        lock.unlock()
        return true
    }
}
