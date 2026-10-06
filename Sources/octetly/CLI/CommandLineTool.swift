import AppKit
import Foundation

/// Puts `octetly` on PATH as a symbolic link to this executable, from the app menu.
///
/// The decisions are pure functions so that they can be tested; `CommandLineToolInstaller` below
/// is the part that looks at the disk, asks, and links.
enum CommandLineTool {
    static let linkPath = "/usr/local/bin/octetly"

    /// What is at the link path now. A symlink's destination is absolute and has its own symlinks
    /// resolved, so that it compares with the executable's path.
    enum Existing: Equatable {
        case nothing
        case symlink(to: String)
        /// A file or folder Octetly did not put there.
        case other
    }

    enum Plan: Equatable {
        case install
        case replace(previous: String)
        case alreadyInstalled
        case blocked
    }

    /// Why this copy of the app cannot be the target of a link that has to outlive it.
    enum LocationProblem: Equatable {
        /// Gatekeeper is running a quarantined copy from a random path that is gone after it quits.
        case translocated
        /// The disk image the app shipped in, which goes away when it is ejected.
        case readOnlyVolume
        /// A `swift run` build, which the next clean or rebuild replaces or removes.
        case notInApp
    }

    static func plan(existing: Existing, executable: String) -> Plan {
        switch existing {
        case .nothing:
            .install
        case .symlink(let destination):
            destination == executable ? .alreadyInstalled : .replace(previous: destination)
        case .other:
            .blocked
        }
    }

    static func locationProblem(executable: String, onReadOnlyVolume: Bool) -> LocationProblem? {
        if executable.contains("/AppTranslocation/") { return .translocated }
        if onReadOnlyVolume { return .readOnlyVolume }
        if !executable.contains(".app/Contents/MacOS/") { return .notInApp }
        return nil
    }

    struct LinkError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Makes `link` a symbolic link to `target`, replacing a symbolic link already there but never
    /// a file or a folder.
    ///
    /// System calls rather than `ln`, because a shell can only look at what is at the path and then
    /// act on it as a second step, and something can be put there in between. Here every step either
    /// creates a name that must not exist yet (`RENAME_EXCL`) or works on an entry already moved to a
    /// name of its own: what is at the path is moved aside first and deleted only once it is seen to
    /// be a link, and anything else is moved back. `symlink(2)` also never makes the link inside a
    /// folder, which `ln -s` does when one is at the path.
    ///
    /// What this guards against is the user's own mistakes and slow dialogs, not an adversary. The
    /// moved-aside name is still a path, and something that can write to the folder can swap it
    /// between the check and the unlink. This runs only in a folder the user can write to, so
    /// that is something running as the user, or root, either of which could delete the entry
    /// directly.
    static func link(_ target: String, at link: String) throws {
        // The app can be moved while the confirmation is up, and a link to where it was is no use.
        guard FileManager.default.isExecutableFile(atPath: target) else {
            throw LinkError(message: "\(target) is not there any more.")
        }
        let directory = (link as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw LinkError(message: error.localizedDescription)
        }

        let staged = "\(directory)/.octetly-\(UUID().uuidString)"
        guard symlink(target, staged) == 0 else { throw failure("Could not create a link in \(directory)") }
        var placed = false
        defer { if !placed { unlink(staged) } }

        var aside: String?
        var info = stat()
        if lstat(link, &info) == 0 {
            let moved = "\(directory)/.octetly-old-\(UUID().uuidString)"
            guard renamex_np(link, moved, UInt32(RENAME_EXCL)) == 0 else {
                throw failure("Could not move \(link) aside")
            }
            guard lstat(moved, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else {
                guard renamex_np(moved, link, UInt32(RENAME_EXCL)) == 0 else {
                    throw LinkError(message: "\(link) is not a symbolic link. It is now at \(moved), "
                                    + "because something else took its name while it was checked.")
                }
                throw LinkError(message: "\(link) is not a symbolic link, so Octetly left it alone.")
            }
            aside = moved
        }

        guard renamex_np(staged, link, UInt32(RENAME_EXCL)) == 0 else {
            let error = failure("Could not create \(link)")
            if let aside, renamex_np(aside, link, UInt32(RENAME_EXCL)) != 0 { unlink(aside) }
            throw error
        }
        placed = true
        if let aside { unlink(aside) }
    }

    /// The shell command that makes the link as root, for a folder this user cannot write to.
    ///
    /// Only system tools, so that nothing the user can write runs as root; re-running Octetly
    /// itself would let a process that can replace the app's executable swap it while the password
    /// prompt is up. The shell cannot replace "only a link" in one step the way `link(_:at:)` does,
    /// but in a folder only root can write to, only root could slip something between the steps.
    /// They are still re-checked here, because the confirmation and the prompt come between the
    /// plan and this: `-x` for an app moved meanwhile, `-e` for a folder, which `ln -s` would make
    /// the link inside, and no `-f`, so that a file is a failure rather than a deletion.
    static func privilegedCommand(linking target: String, at link: String) -> String {
        let directory = (link as NSString).deletingLastPathComponent
        let quotedLink = shellQuoted(link)
        return "[ -x \(shellQuoted(target)) ]"
            + " && /bin/mkdir -p \(shellQuoted(directory))"
            + " && { [ ! -L \(quotedLink) ] || /bin/rm \(quotedLink); }"
            + " && [ ! -e \(quotedLink) ]"
            + " && /bin/ln -s \(shellQuoted(target)) \(quotedLink)"
    }

    private static func failure(_ what: String) -> LinkError {
        LinkError(message: "\(what): \(String(cString: strerror(errno))).")
    }

    /// One argument to /bin/sh whatever it contains. An app can be renamed to anything, quotes
    /// included, and the command it goes into runs as root.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// An AppleScript string literal holding `value`.
    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"\(escaped)\""
    }
}

/// The menu command behind "Install Command-Line Tool…".
@MainActor
enum CommandLineToolInstaller {
    static func run() {
        let link = CommandLineTool.linkPath
        guard let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        let executable = executableURL.path

        let readOnly = (try? executableURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly ?? false
        switch CommandLineTool.locationProblem(executable: executable, onReadOnlyVolume: readOnly) {
        case .translocated:
            inform("Move Octetly to the Applications folder first.",
                   "macOS is running this copy from a temporary location, and a link to it would "
                   + "stop working once Octetly quits.")
            return
        case .readOnlyVolume:
            inform("Copy Octetly to the Applications folder first.",
                   "This copy is on a read-only volume such as the disk image, and a link to it "
                   + "would stop working once the volume is ejected.")
            return
        case .notInApp:
            inform("Install the command from Octetly.app.",
                   "This copy is not inside an app, as with `swift run`, and a link to it would "
                   + "break on the next clean or rebuild.")
            return
        case nil:
            break
        }

        switch CommandLineTool.plan(existing: existing(at: link), executable: executable) {
        case .alreadyInstalled:
            inform("The octetly command is already installed.",
                   "\(link) points to this copy of Octetly.")
            return
        case .blocked:
            inform("\(link) is not a symbolic link.",
                   "Octetly did not create it and will not overwrite it. Remove it and try again.")
            return
        case .install:
            guard confirm("Install the octetly command?",
                          "This creates a symbolic link at \(link) pointing to:\n\n\(executable)\n\n"
                          + "macOS asks for an administrator password if that folder needs one. "
                          + "If you move Octetly, install the command again.",
                          button: "Install") else { return }
        case .replace(let previous):
            guard confirm("Replace the octetly command?",
                          "\(link) points to:\n\n\(previous)\n\nIt will point to:\n\n\(executable)",
                          button: "Replace") else { return }
        }

        let directory = (link as NSString).deletingLastPathComponent
        var outcome: Outcome
        if FileManager.default.isWritableFile(atPath: directory) {
            do {
                try CommandLineTool.link(executable, at: link)
                outcome = .done
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        } else {
            outcome = runAsAdministrator(
                CommandLineTool.privilegedCommand(linking: executable, at: link))
        }

        if case .done = outcome,
           existing(at: link) != .symlink(to: executable)
            || !FileManager.default.isExecutableFile(atPath: link) {
            outcome = .failed("\(link) does not point to this copy of Octetly after installing.")
        }

        switch outcome {
        case .done:
            inform("Installed the octetly command.", "Run `octetly help` in a new Terminal window.")
        case .cancelled:
            break
        case .failed(let message):
            inform("Could not install the octetly command.",
                   message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private enum Outcome {
        case done
        case cancelled
        case failed(String)
    }

    private static func existing(at link: String) -> CommandLineTool.Existing {
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link) {
            let directory = URL(fileURLWithPath: (link as NSString).deletingLastPathComponent)
            return .symlink(to: URL(fileURLWithPath: destination, relativeTo: directory)
                .resolvingSymlinksInPath().path)
        }
        return manager.fileExists(atPath: link) ? .other : .nothing
    }

    private static func runAsAdministrator(_ command: String) -> Outcome {
        let source = "do shell script \(CommandLineTool.appleScriptLiteral(command))"
            + " with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .done }
        // -128 is userCanceledErr: the password prompt was dismissed, which needs no message.
        if error[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "The command failed.")
    }

    private static func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private static func confirm(_ message: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
