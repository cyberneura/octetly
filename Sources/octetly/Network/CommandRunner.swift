import Foundation

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) async -> String {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
            } catch {
                return ""
            }
        }.value
    }
}
