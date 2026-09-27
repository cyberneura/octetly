import Dispatch
import Foundation

/// Opens the window, or runs a command and exits when the arguments name one.
///
/// One executable for both, so the released app is also the command: the cask puts nothing else
/// on disk to run. `CLICommand.parse` decides which, and it returns nil for anything it does not
/// know, so a launch from Finder or Xcode still gets its window.
@main
@MainActor
enum OctetlyMain {
    static func main() {
        let command: CLICommand?
        do {
            command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            CLITool.note(error.localizedDescription)
            CLITool.note("run `octetly help` for usage.")
            exit(2)
        }
        guard let command else {
            OctetlyApp.main()
            return
        }
        // Never activated as an app, so no Dock icon and no window. The main queue still has to be
        // served for the main-actor task to run, which is all dispatchMain() does here.
        Task {
            let status = await CLITool.run(command)
            exit(status)
        }
        dispatchMain()
    }
}
