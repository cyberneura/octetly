import Foundation

enum CommandRunner {
    // Watchdogs get a queue that is never blocked, so the timeout still fires while every thread
    // running helpers is parked in one. It sends SIGTERM once and does not escalate: a helper
    // that ignored it would hold its thread until it exited on its own. Every helper this app
    // runs (ping, arp, ndp, dig, smbutil) honours SIGTERM.
    fileprivate static let watchdogQueue = DispatchQueue(label: "com.cyberneura.octetly.command.watchdog")

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) async -> String {
        let helper = Helper()
        return await withTaskCancellationHandler {
            await BlockingWork.run { helper.run(executable, arguments, timeout: timeout) }
        } onCancel: {
            helper.cancel()
        }
    }
}

/// Owns one child process. Unchecked because a Process is reachable from both the thread running
/// it and a cancelling task; the lock is what actually keeps that safe.
private final class Helper: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        // A helper that inherits the app's stdin can sit forever waiting on input that never comes.
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return ""
        }
        self.process = process
        lock.unlock()

        defer { clear() }
        do {
            try process.run()
        } catch {
            return ""
        }
        // Cancellation between publishing the Process above and launching it here would have
        // found isRunning false and done nothing, leaving the helper to run to its timeout.
        lock.lock()
        let cancelledDuringLaunch = cancelled
        lock.unlock()
        if cancelledDuringLaunch { process.terminate() }

        let watchdog = DispatchWorkItem { [weak self] in self?.terminate() }
        CommandRunner.watchdogQueue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Draining before waiting matters: a child blocked writing into a pipe nobody reads can
        // never exit, so waiting first would hang on exactly the helpers that produce output.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        terminate()
    }

    private func terminate() {
        lock.lock()
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
    }

    private func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}
