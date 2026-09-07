import Foundation

/// Turning what dig(1) prints into a name fit to put in a row.
enum DNSName {
    static let none = "—"

    /// The name a `+short` answer ends at, or "—".
    ///
    /// The last one where there are several. A reverse zone delegated classlessly (RFC 2317) has
    /// dig follow a CNAME to reach the PTR, and `+short` prints the chain without saying which line
    /// is which: taking the first put the CNAME's target — `1.0/25.0.168.192.in-addr.arpa` — in the
    /// Name column. The PTR is what the chain ends at. Where the lines are several PTRs instead,
    /// one has to be picked and neither end is better.
    ///
    /// A chain that stops at the CNAME is refused outright rather than shown: the reverse zones
    /// have names of their own, and one of those is never what a host is called.
    ///
    /// Lines beginning with ";" are dropped because dig says so much on the way to saying nothing.
    /// `+short` silences the banner, but a query that could not reach the server still prints
    /// `;; connection timed out; no servers could be reached` — measured, on stdout — and
    /// CommandRunner hands stdout and stderr back as one string, so there is no stream left to tell
    /// diagnostics apart by. Taking the first line regardless put that sentence in the Name column
    /// of every host that could not be reached. For the mDNS query in ScanEngine that is the
    /// ordinary case rather than an edge one: most hosts run no responder at all.
    ///
    /// Any `;` line, not that one: dig's banner comes back as soon as `+short` follows the query it
    /// was meant for rather than preceding it, and a filter that recognised only the message
    /// measured here would be one argument away from putting `; <<>> DiG 9.10.6 <<>> …` in the
    /// column instead.
    ///
    /// Not everything dig says begins with a `;`, though — a fatal one is
    /// `/usr/bin/dig: couldn't get address for '…': not found`, measured — so this is the second
    /// filter rather than the only one. The first is the exit status, which ScanEngine checks
    /// before anything reaches here: nothing dig printed on its way to failing is a name.
    static func answer(in output: String) -> String {
        var answer = none
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix(";") else { continue }
            let name = decoded(text)
            guard !name.isEmpty, !isReverseZone(name) else { continue }
            answer = name
        }
        return answer
    }

    /// Decodes DNS presentation format and drops the trailing root dot.
    ///
    /// `\DDD` is one byte in decimal and `\X` is a literal X. A Hisense television on this
    /// project's own network answers to `hisensetv\010.local.`, where 10 is a line feed: left
    /// undecoded it reads in the row as a backslash and three digits, and decoded it breaks the row
    /// apart. So what the escapes produce is filtered rather than trusted — a name reaching here is
    /// only ever displayed, and nothing below a space can be part of one.
    ///
    /// The root dot comes off first, before any escape is read, because it is defined by not being
    /// escaped and that is a fact about the text as written. Decoding first and then stripping
    /// trailing dots cannot tell it from a `\.` or a `\046` that a label genuinely ends with, and
    /// turned `host\046.` — the name `host.`, terminated — into `host`.
    static func decoded(_ text: String) -> String {
        var bytes: [UInt8] = []
        var rest = Array(withoutRootDot(text.trimmingCharacters(in: .whitespaces)).utf8)[...]
        while let byte = rest.popFirst() {
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                continue
            }
            let digits = rest.prefix(3)
            // A three-digit run that is not a byte value is not an escape: `\999` is three nines,
            // so it falls through to the literal case rather than being swallowed.
            if digits.count == 3, digits.allSatisfy(isDigit),
               let value = UInt16(String(decoding: digits, as: UTF8.self)), value < 256 {
                bytes.append(UInt8(value))
                rest = rest.dropFirst(3)
            } else if let literal = rest.popFirst() {
                bytes.append(literal)
            }
        }
        // Filtered by scalar rather than by byte. A byte-wise test keeps anything from 0x20 up, and
        // the characters that break a row worst are all above it once decoded: `\226\128\168` is
        // three innocent-looking bytes that reassemble into U+2028, which ends the line the name is
        // being displayed on. The bidi controls are the same shape of problem — they reorder what
        // is around them rather than ending it.
        //
        // Whitespace is trimmed again because an escape can produce it, as the line feed measured
        // above shows. Dots are not: by here every one that remains is part of a label.
        let printable = String(decoding: bytes, as: UTF8.self)
            .unicodeScalars.filter { !unprintable.contains($0) }
        return String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
    }

    /// What may not survive into a row: the characters that end the line it is drawn on or reorder
    /// what is around it.
    ///
    /// Listed rather than taken by category, after two goes at the category. Foundation's
    /// `controlCharacters` is the whole of Cc *and Cf*, and Cf is where the characters that compose
    /// text sit alongside the ones that break it — taking it whole cost `👨‍💻` its zero-width joiner
    /// and left `👨💻`, cost the zero-width non-joiner that Persian and several Indic scripts spell
    /// words with, and cost `🏴󠁧󠁢󠁥󠁮󠁧󠁿` the six tag characters that say which flag it is, leaving a
    /// plain black one. Each of those was a separate exception bolted on; naming the harm instead
    /// is a rule that does not grow every time Unicode adds another way to compose a character.
    ///
    /// Nothing invisible is removed for being invisible. A zero-width character cannot make a row
    /// say something false; the ones that can are here, and that is the whole of the rule — the
    /// separators, the bidi controls, and the deprecated shaping and annotation controls that
    /// rewrite what is drawn around them.
    ///
    /// `illegalCharacters` was in this set and is not any more. It is a category again, and worse,
    /// one whose contents are whatever the ICU that shipped with this macOS thinks is unassigned:
    /// on the oldest version this app supports it would silently swallow every character Unicode
    /// has added since. Nothing it caught can break a row anyway — an unassigned scalar draws as a
    /// box — and a malformed byte sequence has already become U+FFFD by the time it reaches here.
    private static let unprintable: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{0000}"..."\u{001F}")  // C0 controls, tab and newline among them
        set.insert(charactersIn: "\u{007F}"..."\u{009F}")             // DEL, then the C1 controls
        set.insert(charactersIn: "\u{2028}"..."\u{2029}")             // line and paragraph separators
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")             // bidi embeddings and overrides
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")             // bidi isolates
        set.insert("\u{061C}")                                        // Arabic letter mark
        set.insert(charactersIn: "\u{200E}"..."\u{200F}")             // left-to-right and right-to-left marks
        set.insert(charactersIn: "\u{206A}"..."\u{206F}")             // deprecated shaping and digit-shape controls
        set.insert(charactersIn: "\u{FFF9}"..."\u{FFFB}")             // interlinear annotation, which hides its text
        return set
    }()

    /// `text` without its terminating root dot, if it has one.
    ///
    /// A final dot is the root only when it is not itself escaped, and what decides that is how
    /// many backslashes run up to it: an even number leaves the dot bare, an odd number spends the
    /// last one on it. `host\.` is a label ending in a dot and `host\\.` is a label ending in a
    /// backslash, terminated.
    private static func withoutRootDot(_ text: String) -> String {
        guard text.hasSuffix(".") else { return text }
        let body = text.dropLast()
        let backslashes = body.reversed().prefix { $0 == "\\" }.count
        return backslashes.isMultiple(of: 2) ? String(body) : text
    }

    /// Whether a name belongs to a reverse-lookup zone rather than to a host.
    ///
    /// `dig -x` walks these to reach a PTR and prints what it walked through, so one reaching a row
    /// means the walk stopped short — a classless delegation whose CNAME target has no PTR behind
    /// it. There is no host called `1.0/25.0.168.192.in-addr.arpa`.
    static func isReverseZone(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".in-addr.arpa") || lowered.hasSuffix(".ip6.arpa")
    }

    /// Whether a name sits in the `.local` namespace.
    ///
    /// A namespace and not a provenance: `.local` says the name belongs to mDNS, not that this
    /// answer came from the host's own responder. A resolver can hold one in a zone, a cache, or a
    /// relay, and `multicastName(dns:responder:)` is where that difference is acted on.
    ///
    /// Case-insensitively. DNS comparisons ignore ASCII case (RFC 4343) and nothing between the
    /// responder and here normalises it, so a host answering `Printer.Local` is making the same
    /// claim as one answering `printer.local`.
    static func isMulticast(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".local")
    }

    /// The mDNS name for a row, given what the resolver said and what the host itself said.
    ///
    /// The host wins whenever it answered. A `.local` from the resolver stands in only for silence,
    /// because a suffix is not evidence of where the answer came from or of it being current — this
    /// used to skip asking the host at all when the resolver's answer ended in `.local`, which is a
    /// stale cache entry outranking the machine it names.
    static func multicastName(dns: String, responder: String) -> String {
        if responder != none { return responder }
        return isMulticast(dns) ? dns : none
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

}
