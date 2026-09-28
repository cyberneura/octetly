import Foundation
import Testing

@testable import Octetly

@Suite("Licenses")
struct LicenseTests {
    /// The top of the repository, found from this file rather than from the working directory.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ path: String) throws -> String {
        // Normalised so that a checkout with CRLF line endings compares the same.
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    @Test("--license is a command in first position only")
    func parse() throws {
        #expect(try CLICommand.parse(["--license"]) == .license)
        #expect(try CLICommand.parse(["license"]) == .license)
        // After an argument macOS added, nothing is read as a command and the window opens.
        #expect(try CLICommand.parse(["-psn_0_12345", "--license"]) == nil)
        #expect(throws: CLIError.unknownOption("--license", command: "lookup")) {
            try CLICommand.parse(["lookup", "--license", "nas.local"])
        }
    }

    // SwiftPM can only bundle files inside the target, so the app carries copies. A copy that has
    // drifted from the file at the top of the repository is what this catches.
    @Test("The bundled copies match LICENSE and THIRD-PARTY-NOTICES.txt")
    func copiesMatch() throws {
        #expect(try Self.read("Sources/octetly/Resources/LICENSE.txt") == Self.read("LICENSE"))
        #expect(try Self.read("Sources/octetly/Resources/THIRD-PARTY-NOTICES.txt")
            == Self.read("THIRD-PARTY-NOTICES.txt"))
    }

    // The notices say no package is bundled; that stops being true the moment one is added.
    @Test("The notices account for the package's dependencies")
    func noticesMatchDependencies() throws {
        // Whitespace removed, so that `.package` and its `(` on separate lines still count.
        let manifest = try Self.read("Package.swift").filter { !$0.isWhitespace }
        let notices = try Self.read("THIRD-PARTY-NOTICES.txt")
        if !manifest.contains(".package(") {
            #expect(notices.contains("Octetly does not bundle any third-party library."))
        } else {
            #expect(!notices.contains("Octetly does not bundle any third-party library."))
        }
    }

    @Test("The text shown in the app carries both files")
    func text() throws {
        let text = try #require(Licenses.text())
        #expect(text.contains("MIT License"))
        #expect(text.contains("Copyright (c) 2026 Cyberneura"))
        #expect(text.contains("THIRD-PARTY NOTICES"))
    }
}
