import Foundation
import Darwin

struct ProcessResult: Sendable {
    let standardOutputData: Data
    let standardErrorData: Data
    let terminationStatus: Int32

    var succeeded: Bool { terminationStatus == 0 }
    var standardOutput: String { String(data: standardOutputData, encoding: .utf8) ?? "" }
    var standardError: String { String(data: standardErrorData, encoding: .utf8) ?? "" }
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(TimeInterval)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not launch command: \(message)"
        case .timedOut(let seconds):
            return "Command timed out after \(seconds.formatted()) seconds"
        case .cancelled:
            return "Command was cancelled"
        }
    }
}

/// Runs external tools without attaching bounded pipes. Output is redirected
/// to per-command temporary files, so verbose commands cannot deadlock while
/// waiting for the parent to drain stdout or stderr.
enum ProcessRunner {
    fileprivate static let terminationGrace: TimeInterval = 0.5

    @concurrent
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let execution = try ProcessExecution(executable: executable, arguments: arguments)

        do {
            try execution.start()
            let status = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Int32.self) { group in
                    group.addTask { await execution.waitForTermination() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw ProcessRunnerError.timedOut(timeout)
                    }

                    do {
                        guard let status = try await group.next() else {
                            throw ProcessRunnerError.launchFailed("No termination result")
                        }
                        group.cancelAll()
                        return status
                    } catch {
                        execution.terminate()
                        group.cancelAll()
                        throw error
                    }
                }
            } onCancel: {
                execution.terminate()
            }

            if Task.isCancelled {
                throw ProcessRunnerError.cancelled
            }

            return try execution.result(status: status)
        } catch {
            execution.terminate()
            execution.cleanup()
            throw error
        }
    }

    /// Compatibility bridge for legacy synchronous call sites. Unlike the
    /// old implementation this cannot fill a Pipe and hang before exit.
    static func runSynchronously(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessResult? {
        guard let execution = try? ProcessExecution(executable: executable, arguments: arguments) else {
            return nil
        }

        do {
            try execution.start()
        } catch {
            execution.cleanup()
            return nil
        }

        guard let status = execution.waitSynchronously(timeout: timeout) else {
            execution.terminate()
            _ = execution.waitSynchronously(timeout: terminationGrace + 0.5)
            execution.cleanup()
            return nil
        }

        return try? execution.result(status: status)
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let outputURL: URL
    private let errorURL: URL
    private let temporaryDirectory: URL
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle
    private let waiter = ProcessWaiter()
    private let stateLock = NSLock()
    private var didCleanup = false

    init(executable: String, arguments: [String]) throws {
        let fm = FileManager.default
        temporaryDirectory = fm.temporaryDirectory
            .appendingPathComponent("CaptrProcess-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        outputURL = temporaryDirectory.appendingPathComponent("stdout")
        errorURL = temporaryDirectory.appendingPathComponent("stderr")
        guard fm.createFile(atPath: outputURL.path, contents: nil),
              fm.createFile(atPath: errorURL.path, contents: nil) else {
            try? fm.removeItem(at: temporaryDirectory)
            throw ProcessRunnerError.launchFailed("Could not create output files")
        }

        outputHandle = try FileHandle(forWritingTo: outputURL)
        errorHandle = try FileHandle(forWritingTo: errorURL)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.terminationHandler = { [waiter] process in
            waiter.complete(status: process.terminationStatus)
        }
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
    }

    func waitForTermination() async -> Int32 {
        await waiter.wait()
    }

    func waitSynchronously(timeout: TimeInterval) -> Int32? {
        waiter.waitSynchronously(timeout: timeout)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ProcessRunner.terminationGrace) {
            if processIsRunning(pid) {
                kill(pid, SIGKILL)
            }
        }
    }

    func result(status: Int32) throws -> ProcessResult {
        try? outputHandle.close()
        try? errorHandle.close()

        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        let error = (try? Data(contentsOf: errorURL)) ?? Data()
        cleanup()
        return ProcessResult(standardOutputData: output, standardErrorData: error, terminationStatus: status)
    }

    func cleanup() {
        stateLock.lock()
        guard !didCleanup else {
            stateLock.unlock()
            return
        }
        didCleanup = true
        stateLock.unlock()

        try? outputHandle.close()
        try? errorHandle.close()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

private final class ProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?
    private var observers: [@Sendable (Int32) -> Void] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func observe(_ observer: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if let status {
            lock.unlock()
            observer(status)
        } else {
            observers.append(observer)
            lock.unlock()
        }
    }

    func waitSynchronously(timeout: TimeInterval) -> Int32? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedProcessStatus()
        observe { status in
            result.set(status)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.get()
    }

    func complete(status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let continuation = self.continuation
        self.continuation = nil
        let observers = self.observers
        self.observers.removeAll()
        lock.unlock()

        continuation?.resume(returning: status)
        observers.forEach { $0(status) }
    }
}

private final class LockedProcessStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    func set(_ status: Int32) {
        lock.withLock { self.status = status }
    }

    func get() -> Int32? {
        lock.withLock { status }
    }
}

private func processIsRunning(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0
}
