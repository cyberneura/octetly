import AppKit
import Foundation
import Testing

@testable import Octetly

@Suite("Command-line tool install")
struct CommandLineToolTests {
    private static let executable = "/Applications/Octetly.app/Contents/MacOS/Octetly"

    @Test("An empty path is installed, a link to this copy is left, any other link is replaced")
    func plan() {
        #expect(CommandLineTool.plan(existing: .nothing, executable: Self.executable) == .install)
        #expect(CommandLineTool.plan(existing: .symlink(to: Self.executable),
                                     executable: Self.executable) == .alreadyInstalled)
        let old = "/Volumes/Octetly/Octetly.app/Contents/MacOS/Octetly"
        #expect(CommandLineTool.plan(existing: .symlink(to: old), executable: Self.executable)
            == .replace(previous: old))
        #expect(CommandLineTool.plan(existing: .other, executable: Self.executable) == .blocked)
    }

    @Test("A translocated, read-only or swift run copy is refused as a link target")
    func locationProblem() {
        let translocated = "/private/var/folders/xy/T/AppTranslocation/1A2B/d/Octetly.app/Contents/MacOS/Octetly"
        #expect(CommandLineTool.locationProblem(executable: translocated, onReadOnlyVolume: true)
            == .translocated)
        #expect(CommandLineTool.locationProblem(executable: Self.executable, onReadOnlyVolume: true)
            == .readOnlyVolume)
        #expect(CommandLineTool.locationProblem(executable: Self.executable, onReadOnlyVolume: false)
            == nil)
        #expect(CommandLineTool.locationProblem(
            executable: "/src/octetly/.build/arm64-apple-macosx/debug/Octetly", onReadOnlyVolume: false)
            == .notInApp)
    }

    @Test("A link is made in a missing folder and replaces a link already there")
    func linkReplacesLink() throws {
        // Arrange
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Self.executableFile(in: root, named: "first")
        let second = try Self.executableFile(in: root, named: "second")
        let link = root.appendingPathComponent("bin dir/octetly").path

        // Act
        try CommandLineTool.link(first, at: link)
        try CommandLineTool.link(second, at: link)

        // Assert
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == second)
        #expect(try Self.entries(beside: link) == ["octetly"])
    }

    @Test("A file at the link path is neither replaced nor deleted")
    func linkKeepsFiles() throws {
        // Arrange
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try Self.executableFile(in: root, named: "target")
        let link = root.appendingPathComponent("bin/octetly").path
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: link))

        // Act
        #expect(throws: CommandLineTool.LinkError.self) { try CommandLineTool.link(target, at: link) }

        // Assert
        #expect(try String(contentsOfFile: link, encoding: .utf8) == "keep")
        #expect(try Self.entries(beside: link) == ["octetly"])
    }

    // `ln -s` given a folder succeeds by making the link inside it.
    @Test("A folder at the link path is left empty")
    func linkKeepsFolders() throws {
        // Arrange
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try Self.executableFile(in: root, named: "target")
        let link = root.appendingPathComponent("bin/octetly").path
        try FileManager.default.createDirectory(atPath: link, withIntermediateDirectories: true)

        // Act
        #expect(throws: CommandLineTool.LinkError.self) { try CommandLineTool.link(target, at: link) }

        // Assert
        #expect(try FileManager.default.contentsOfDirectory(atPath: link).isEmpty)
        #expect(try Self.entries(beside: link) == ["octetly"])
    }

    @Test("No link is made to an app that has gone")
    func linkNeedsTarget() throws {
        // Arrange
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("octetly").path

        // Act
        #expect(throws: CommandLineTool.LinkError.self) {
            try CommandLineTool.link(root.appendingPathComponent("moved").path, at: link)
        }

        // Assert
        #expect(!FileManager.default.fileExists(atPath: link))
    }

    // Run by a real shell, as the user rather than root, in a folder of its own. The target's name
    // carries every character the quoting has to survive, so a quoting mistake shows up as a
    // missing link or a link to the wrong place.
    @Test("The privileged command links into a missing folder and replaces a link")
    func privilegedCommandLinks() throws {
        // Arrange
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Self.executableFile(in: root, named: #"It's "Octetly" $HOME `id`"#)
        let second = try Self.executableFile(in: root, named: "second")
        let link = root.appendingPathComponent("bin dir/octetly").path

        // Act
        let firstStatus = try Self.shell(CommandLineTool.privilegedCommand(linking: first, at: link))
        let firstDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link)
        let secondStatus = try Self.shell(CommandLineTool.privilegedCommand(linking: second, at: link))

        // Assert
        #expect(firstStatus == 0)
        #expect(firstDestination == first)
        #expect(secondStatus == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == second)
    }

    @Test("The privileged command leaves a file and a folder alone, and needs the target")
    func privilegedCommandRefuses() throws {
        // Arrange
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try Self.executableFile(in: root, named: "target")
        let file = root.appendingPathComponent("file").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: file))
        let folder = root.appendingPathComponent("folder").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let unused = root.appendingPathComponent("unused").path

        // Act
        let fileStatus = try Self.shell(CommandLineTool.privilegedCommand(linking: target, at: file))
        let folderStatus = try Self.shell(CommandLineTool.privilegedCommand(linking: target, at: folder))
        let movedStatus = try Self.shell(
            CommandLineTool.privilegedCommand(linking: root.appendingPathComponent("moved").path, at: unused))

        // Assert
        #expect(fileStatus != 0)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep")
        #expect(folderStatus != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)
        #expect(movedStatus != 0)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: unused)) == nil)
    }

    @Test("The AppleScript literal reads back as the string it was made from")
    @MainActor
    func appleScriptLiteral() throws {
        // Arrange
        let value = #"/bin/ln -s 'a\b' "c" && echo \"done\""#

        // Act
        let script = NSAppleScript(source: "return \(CommandLineTool.appleScriptLiteral(value))")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)

        // Assert
        #expect(error == nil)
        #expect(result?.stringValue == value)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("octetly-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func executableFile(in directory: URL, named name: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// What is in the link's folder, so that a staged or moved-aside entry left behind shows up.
    private static func entries(beside link: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (link as NSString).deletingLastPathComponent)
            .sorted()
    }

    private static func shell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
