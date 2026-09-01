import Foundation

/// Runs blocking work off Swift concurrency's cooperative pool.
///
/// That pool is only as wide as the core count, so a handful of blocked threads starves it: the
/// tasks that would have timed the blocking work out never get a thread to resume on, and the
/// work they would have cancelled is what the threads are stuck in. Anything that parks a thread
/// — waitUntilExit(), poll(), a socket read — goes through here instead.
enum BlockingWork {
    private static let queue = DispatchQueue(label: "com.cyberneura.octetly.blocking",
                                             attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
