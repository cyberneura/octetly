import Foundation

enum CommandRunner {
    // Watchdogs get a queue that is never blocked, so the timeout still fires while every thread
    // running helpers is parked in one. It sends SIGTERM once and does not escalate: a helper
    // that ignored it would hold its thread until it exited on its own. Every helper this app
    // runs (ping, arp, ndp, dig, smbutil) honours SIGTERM.
    fileprivate static let watchdogQueue = DispatchQueue(label: "com.cyberneura.octetly.command.watchdog")

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) async -> String {
        await runChecked(executable, arguments, timeout: timeout).output
    }

    /// The output, and whether the helper exited cleanly: ran to its own end and returned zero.
    ///
    /// A helper killed part way and one that failed on its own both come back false, which is what
    /// the caller wants — neither produced output that a missing line can be read as meaning
    /// anything. What matters is only that either can be told from success at all, and both can:
    /// Foundation reports a signal death as `.uncaughtSignal` and a self-inflicted failure as
    /// `.exit` with a non-zero status, so nothing has to be recorded on the way in and raced
    /// against.
    ///
    /// `run` throws the distinction away, which is right for a helper read line by line: half of
    /// dig(1)'s answer is no worse than none of it. It is wrong wherever the *absence* of a line is
    /// read as meaning something, because a torn read then looks exactly like a real answer of
    /// "nothing". The neighbour cache is read that way — a partial ndp(8) is indistinguishable
    /// from a segment with nothing on it, and acting on one gives every host it is missing a
    /// second row.
    static func runChecked(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 2) async -> (output: String, completed: Bool) {
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

    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) -> (output: String, completed: Bool) {
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
            return ("", false)
        }
        self.process = process
        lock.unlock()

        defer { clear() }
        do {
            try process.run()
        } catch {
            return ("", false)
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

        // Read off the child itself rather than recorded on the way in. Measured: a `sleep 5` cut
        // short by terminate() reports uncaughtSignal with status 15, `false` reports exit with
        // status 1, and a helper that ran reports exit with 0.
        //
        // Watching the watchdog instead was tried and is worse: `DispatchWorkItem.cancel()` does
        // not stop a block that has already begun, so a child exiting just as the deadline lands
        // would be recorded as timed out while its output was in fact complete.
        return (String(decoding: data, as: UTF8.self),
                process.terminationReason == .exit && process.terminationStatus == 0)
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
