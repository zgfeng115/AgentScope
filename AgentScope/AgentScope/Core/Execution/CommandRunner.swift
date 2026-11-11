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

        func drain(_ pipe: Pipe, into collector: PipeOutputCollector) {
            outputGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                outputGroup.leave()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                outputGroup.notify(queue: .global(qos: .userInitiated)) {
                    let result = CommandResult(
                        stdout: Self.string(from: stdoutCollector.data),
                        stderr: Self.string(from: stderrCollector.data),
                        exitCode: process.terminationStatus,
                        timedOut: state.hasTimedOut,
                        duration: Date().timeIntervalSince(startedAt)
                    )

                    if result.timedOut {
                        state.resumeFailure(CommandRunnerError.timedOut(result), continuation: continuation)
                    } else if result.exitCode != 0 {
                        state.resumeFailure(CommandRunnerError.nonZeroExit(result), continuation: continuation)
                    } else {
                        state.resumeSuccess(result, continuation: continuation)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                let path = executable.path
                if (error as NSError).code == CocoaError.fileNoSuchFile.rawValue {
                    state.resumeFailure(CommandRunnerError.executableNotFound(path: path), continuation: continuation)
                } else {
                    state.resumeFailure(CommandRunnerError.permissionDenied(path: path), continuation: continuation)
                }
                return
            }

            drain(stdoutPipe, into: stdoutCollector)
            drain(stderrPipe, into: stderrCollector)

            let effectiveTimeout = max(timeout, 0.001)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + effectiveTimeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
            }
        }
    }

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

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
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
