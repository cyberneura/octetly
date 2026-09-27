import Testing

@testable import Octetly

@Suite("CLICommand")
struct CLICommandTests {
    @Test("No command opens the window")
    func windowLaunches() throws {
        #expect(try CLICommand.parse([]) == nil)
        // What macOS and Xcode put on the command line of an app they launch. Reading these as a
        // mistyped command would turn a launch into an error message.
        #expect(try CLICommand.parse(["-psn_0_12345"]) == nil)
        #expect(try CLICommand.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test("Help and version")
    func helpAndVersion() throws {
        #expect(try CLICommand.parse(["help"]) == .help)
        #expect(try CLICommand.parse(["--help"]) == .help)
        #expect(try CLICommand.parse(["-h"]) == .help)
        #expect(try CLICommand.parse(["version"]) == .version)
        #expect(try CLICommand.parse(["--version"]) == .version)
    }

    @Test("lookup takes names and addresses, in order")
    func lookup() throws {
        #expect(try CLICommand.parse(["lookup", "nas.local", "192.168.0.5", "fe80::1%en0"])
            == .lookup(targets: ["nas.local", "192.168.0.5", "fe80::1%en0"], json: false))
        #expect(try CLICommand.parse(["lookup", "--json", "nas.local"])
            == .lookup(targets: ["nas.local"], json: true))
        #expect(try CLICommand.parse(["lookup", "nas.local", "--json"])
            == .lookup(targets: ["nas.local"], json: true))
    }

    @Test("lookup refuses what it cannot use")
    func lookupErrors() {
        #expect(throws: CLIError.missingTarget) { try CLICommand.parse(["lookup"]) }
        #expect(throws: CLIError.missingTarget) { try CLICommand.parse(["lookup", "--json"]) }
        // A range belongs to search. Accepting it here would scan nothing and say nothing.
        #expect(throws: CLIError.unknownOption("--range", command: "lookup")) {
            try CLICommand.parse(["lookup", "--range", "10.0.0.0/24", "nas"])
        }
        #expect(throws: CLIError.unexpectedValue("--json")) {
            try CLICommand.parse(["lookup", "--json=yes", "nas"])
        }
    }

    @Test("search takes one word and an optional range, in either spelling")
    func search() throws {
        let range = try ScanRange.parse("10.8.0.0/24")
        #expect(try CLICommand.parse(["search", "nas", "--range", "10.8.0.0/24"])
            == .search(query: "nas", range: range, json: false))
        #expect(try CLICommand.parse(["search", "--range=10.8.0.0/24", "nas"])
            == .search(query: "nas", range: range, json: false))
        #expect(try CLICommand.parse(["search", "-r", "10.8.0.0/24", "--json", "nas"])
            == .search(query: "nas", range: range, json: true))
        #expect(try CLICommand.parse(["search", "nas"]) == .search(query: "nas", range: nil, json: false))
    }

    @Test("search without a word lists every host")
    func searchEverything() throws {
        #expect(try CLICommand.parse(["search"]) == .search(query: nil, range: nil, json: false))
        #expect(try CLICommand.parse(["search", "  "]) == .search(query: nil, range: nil, json: false))
    }

    @Test("Everything after -- is a word, even when it looks like an option")
    func endOfOptions() throws {
        #expect(try CLICommand.parse(["search", "--", "--json"])
            == .search(query: "--json", range: nil, json: false))
        #expect(try CLICommand.parse(["lookup", "--", "-x"]) == .lookup(targets: ["-x"], json: false))
        // Only the bare spelling ends the options; with a value attached it is a typo.
        #expect(throws: CLIError.unknownOption("--", command: "search")) {
            try CLICommand.parse(["search", "--=nas", "--json"])
        }
    }

    @Test("search refuses what it cannot use")
    func searchErrors() {
        #expect(throws: CLIError.tooManyQueries) { try CLICommand.parse(["search", "living", "room"]) }
        #expect(throws: CLIError.missingValue("--range")) { try CLICommand.parse(["search", "--range"]) }
        #expect(throws: CLIError.badRange(.malformedPrefix("33"))) {
            try CLICommand.parse(["search", "--range", "10.0.0.0/33"])
        }
        #expect(throws: CLIError.unknownOption("--ports", command: "search")) {
            try CLICommand.parse(["search", "--ports", "nas"])
        }
    }
}
