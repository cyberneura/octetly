import Foundation

/// What the command line asked for, when it asked for anything.
enum CLICommand: Equatable, Sendable {
    case help
    case version
    /// Octetly's license and the third-party notices.
    case license
    /// Names to addresses through the system resolver, or addresses to names by asking the host.
    case lookup(targets: [String], json: Bool)
    /// A scan of `range` (the automatic one when nil), keeping the hosts that match `query`
    /// (every host when nil).
    case search(query: String?, range: ScanRange?, json: Bool)
    /// What "Install Command-Line Tool…" runs as root when the folder needs an administrator. Not in
    /// the usage: it is there for the app to call, and `sudo` already does the same job by hand.
    case installLink(target: String, link: String)

    /// The command the arguments name, or nil when they name none and the window should open.
    ///
    /// Only a known command in first position counts. macOS and Xcode launch an app with arguments
    /// of their own — `-psn_0_…` from older Finders, `-NSDocumentRevisionsDebugMode YES` from a
    /// debug run — and treating anything unrecognised as a mistyped command would turn those
    /// launches into an error message instead of a window.
    static func parse(_ arguments: [String]) throws -> CLICommand? {
        guard let name = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "help", "--help", "-h":
            return .help
        case "version", "--version":
            return .version
        // Recognised in first position only, like every command here. After anything else it is
        // not looked at, so a launch carrying macOS's own arguments still opens the window.
        case "license", "--license":
            return .license
        case "lookup":
            let options = try Options.parse(rest, command: name, acceptsRange: false)
            guard !options.operands.isEmpty else { throw CLIError.missingTarget }
            return .lookup(targets: options.operands, json: options.json)
        case "search":
            let options = try Options.parse(rest, command: name, acceptsRange: true)
            // One word rather than the operands joined: a shell that split a quoted name apart
            // would otherwise search for something the user never typed, and an unquoted SMB name
            // with a space in it is the likeliest way to get there.
            guard options.operands.count <= 1 else { throw CLIError.tooManyQueries }
            let query = options.operands.first?.trimmingCharacters(in: .whitespaces)
            return .search(query: query?.isEmpty == false ? query : nil,
                           range: options.range, json: options.json)
        case "install-link":
            guard rest.count == 2 else { throw CLIError.installLinkArguments }
            return .installLink(target: rest[0], link: rest[1])
        default:
            return nil
        }
    }

    private struct Options {
        var operands: [String] = []
        var range: ScanRange?
        var json = false

        static func parse(_ arguments: [String], command: String, acceptsRange: Bool) throws -> Options {
            var options = Options()
            var index = arguments.startIndex
            var endOfOptions = false
            while index < arguments.endIndex {
                let argument = arguments[index]
                index += 1
                if endOfOptions || !argument.hasPrefix("-") || argument == "-" {
                    options.operands.append(argument)
                    continue
                }
                // Matched whole, before the split below: `--=x` would otherwise end the options.
                if argument == "--" {
                    endOfOptions = true
                    continue
                }
                // Split off an attached value, so that --range=10.0.0.0/24 and --range 10.0.0.0/24
                // are the same thing.
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let flag = String(parts[0])
                let attached = parts.count > 1 ? String(parts[1]) : nil
                switch flag {
                case "--json":
                    guard attached == nil else { throw CLIError.unexpectedValue(flag) }
                    options.json = true
                // A where clause binds to the one pattern before it, so each needs its own.
                case "--range" where acceptsRange, "-r" where acceptsRange:
                    let value: String
                    if let attached {
                        value = attached
                    } else if index < arguments.endIndex {
                        value = arguments[index]
                        index += 1
                    } else {
                        throw CLIError.missingValue(flag)
                    }
                    do {
                        options.range = try ScanRange.parse(value)
                    } catch let error as ScanRangeError {
                        throw CLIError.badRange(error)
                    }
                default:
                    throw CLIError.unknownOption(flag, command: command)
                }
            }
            return options
        }
    }
}

enum CLIError: LocalizedError, Equatable {
    case missingTarget
    case tooManyQueries
    case missingValue(String)
    case unexpectedValue(String)
    case unknownOption(String, command: String)
    case badRange(ScanRangeError)
    case installLinkArguments

    var errorDescription: String? {
        switch self {
        case .missingTarget:
            "lookup needs a host name or an address."
        case .tooManyQueries:
            "search takes one word; quote it if it has spaces in it."
        case .missingValue(let flag):
            "\(flag) needs a value."
        case .unexpectedValue(let flag):
            "\(flag) does not take a value."
        case .unknownOption(let flag, let command):
            "\(command) has no option \(flag)."
        case .badRange(let error):
            error.errorDescription ?? "The range is not valid."
        case .installLinkArguments:
            "install-link takes a target and a link path."
        }
    }
}
