import Testing

@testable import Octetly

@Suite("DNSName")
struct DNSNameTests {
    @Test("A +short answer is the name")
    func plainAnswer() {
        // Arrange
        let output = "artemis.local.\n"

        // Act
        let name = DNSName.answer(in: output)

        // Assert
        #expect(name == "artemis.local")
    }

    @Test("dig's diagnostics are not a name")
    func rejectsDiagnostics() {
        // Arrange — measured: all a host with no responder produces under +short, on stdout, with
        // nothing on stderr. Every silent host would otherwise be named after this sentence.
        let output = ";; connection timed out; no servers could be reached\n"

        // Act
        let name = DNSName.answer(in: output)

        // Assert
        #expect(name == "—")
    }

    @Test("The banner is not a name either")
    func rejectsTheBanner() {
        // Arrange — the same query with `+short` anywhere but first, which is how dig was being
        // called until the argument order was fixed. Nothing calls it this way now, so what this
        // pins is that the filter reads any diagnostic rather than the one sentence measured above.
        let output = """

        ; <<>> DiG 9.10.6 <<>> @192.168.0.1 -p 5353 -x 192.168.0.1 +short +timeout=1 +tries=1
        ; (1 server found)
        ;; global options: +cmd
        ;; connection timed out; no servers could be reached
        """

        // Act / Assert — Swift's split drops the leading blank line, so the banner is what a
        // first-line-wins parser would have taken.
        #expect(DNSName.answer(in: output) == "—")
    }

    @Test("An answer after a comment is still found")
    func answerAmongComments() {
        // Arrange
        let output = ";; some note\ncasper.local.\n"

        // Act
        let name = DNSName.answer(in: output)

        // Assert
        #expect(name == "casper.local")
    }

    @Test("Nothing at all is not a name")
    func emptyOutput() {
        #expect(DNSName.answer(in: "") == "—")
        #expect(DNSName.answer(in: "\n  \n") == "—")
    }

    @Test("A chain of answers ends at the name")
    func lastOfMany() {
        // dig follows a CNAME to reach the PTR where a reverse zone is delegated classlessly
        // (RFC 2317) and prints both, so the first line is the CNAME's target — an in-addr.arpa
        // name — and the last is the host.
        #expect(DNSName.answer(in: "1.0/25.0.168.192.in-addr.arpa.\nartemis.example.com.\n")
                == "artemis.example.com")
        #expect(DNSName.answer(in: "one.local.\ntwo.local.\n") == "two.local")
        // A diagnostic after the answer is still not the answer.
        #expect(DNSName.answer(in: "artemis.local.\n;; extra\n") == "artemis.local")
    }

    @Test("A chain that stops in the reverse zone names nothing")
    func rejectsReverseZoneNames() {
        // dig walks these to reach a PTR and prints what it walked through, so one arriving as the
        // answer means the walk stopped short — a classless delegation whose CNAME target has no
        // PTR behind it. There is no host by that name.
        #expect(DNSName.answer(in: "1.0/25.0.168.192.in-addr.arpa.\n") == "—")
        #expect(DNSName.answer(in: "1.0.0.0.ip6.arpa.\n") == "—")
        // Case does not save it, and a real name that merely contains the words is not one.
        #expect(DNSName.answer(in: "1.0/25.0.168.192.IN-ADDR.ARPA.\n") == "—")
        #expect(!DNSName.isReverseZone("in-addr.arpa.example.com"))
        // The PTR at the end of a chain is still taken.
        #expect(DNSName.answer(in: "1.0/25.0.168.192.in-addr.arpa.\nartemis.example.com.\n")
                == "artemis.example.com")
    }

    @Test("A decimal escape is the byte it stands for")
    func decodesDecimalEscapes() {
        // Arrange — measured from a Hisense television on this project's own network. Byte 10 is a
        // line feed, which has to be gone before the name reaches a row.
        let raw = "hisensetv\\010.local."

        // Act
        let name = DNSName.decoded(raw)

        // Assert
        #expect(name == "hisensetv.local")
    }

    @Test("A literal escape keeps the character it protects")
    func decodesLiteralEscapes() {
        #expect(DNSName.decoded("my\\ printer.local.") == "my printer.local")
        #expect(DNSName.decoded("a\\\\b.local.") == "a\\b.local")
    }

    @Test("A three-digit run that is not a byte is not an escape")
    func rejectsOutOfRangeEscapes() {
        // 999 is no byte, so the backslash protects the first nine and the rest are themselves.
        #expect(DNSName.decoded("host\\999.local.") == "host999.local")
    }

    @Test("A trailing backslash does not run off the end")
    func toleratesTrailingBackslash() {
        #expect(DNSName.decoded("host\\") == "host")
        #expect(DNSName.decoded("host\\1") == "host1")
    }

    @Test("An escaped dot belongs to the name and the root dot does not")
    func distinguishesEscapedDotFromRootDot() {
        // The root dot is the one that is not escaped. Stripping trailing dots after decoding
        // cannot tell them apart, and turned `host\046.` — the name `host.`, terminated — into
        // `host`.
        #expect(DNSName.decoded("artemis.local.") == "artemis.local")
        #expect(DNSName.decoded("host\\046") == "host.")
        #expect(DNSName.decoded("host\\046.") == "host.")
        #expect(DNSName.decoded("host\\.") == "host.")
        // An even run of backslashes leaves the final dot bare, so this one is the root: the label
        // ends in a backslash.
        #expect(DNSName.decoded("host\\\\.") == "host\\")
    }

    @Test("A .local suffix is recognised whatever its case")
    func multicastIsCaseInsensitive() {
        // DNS comparisons ignore ASCII case and nothing normalises what dig prints, so a responder
        // answering `Printer.Local` is making the same claim as one answering `printer.local`.
        #expect(DNSName.isMulticast("printer.local"))
        #expect(DNSName.isMulticast("Printer.Local"))
        #expect(DNSName.isMulticast("PRINTER.LOCAL"))
        #expect(!DNSName.isMulticast("printer.localdomain"))
        #expect(!DNSName.isMulticast("local"))
        #expect(!DNSName.isMulticast(DNSName.none))
    }

    @Test("The root dot is told from an escaped one at every boundary")
    func rootDotBoundaries() {
        // Nothing to strip.
        #expect(DNSName.decoded("") == "")
        #expect(DNSName.decoded(".") == "")
        #expect(DNSName.decoded("\\") == "")
        #expect(DNSName.decoded("\\\\") == "\\")
        // An odd run of backslashes spends the last one on the dot; an even run leaves it bare.
        #expect(DNSName.decoded("host\\\\\\.") == "host\\.")
        // A root dot straight after a multi-byte character.
        #expect(DNSName.decoded("プリンタ.") == "プリンタ")
    }

    @Test("Characters that would break the row it is shown in do not survive")
    func stripsCharactersThatBreakARow() {
        // \226\128\168 is U+2028, a line separator: every one of those bytes is above a space, so
        // a byte-wise filter passes it through and the name ends the line it is displayed on.
        #expect(DNSName.decoded("host\\226\\128\\168name") == "hostname")
        // U+202E overrides the writing direction of everything after it.
        #expect(DNSName.decoded("host\\226\\128\\174name") == "hostname")
        // A space is not a control character and is part of the name.
        #expect(DNSName.decoded("host\\032name") == "host name")
    }

    @Test("The host outranks a relayed .local, and a relayed one beats silence")
    func multicastNamePrefersTheHost() {
        // The rule this replaced skipped asking the host whenever the resolver's answer ended in
        // .local, which let a stale cache entry outrank the machine it names.
        #expect(DNSName.multicastName(dns: "relay.local", responder: "artemis.local")
                == "artemis.local")
        #expect(DNSName.multicastName(dns: "relay.local", responder: DNSName.none) == "relay.local")
        #expect(DNSName.multicastName(dns: "host.corp.example.com", responder: DNSName.none)
                == DNSName.none)
        #expect(DNSName.multicastName(dns: DNSName.none, responder: "artemis.local")
                == "artemis.local")
        #expect(DNSName.multicastName(dns: DNSName.none, responder: DNSName.none) == DNSName.none)
    }

    @Test("A name in another script survives")
    func keepsNonASCII() {
        // Every byte of one is 0x80 or above, so the control-character filter must not touch them.
        #expect(DNSName.decoded("プリンタ.local.") == "プリンタ.local")
        #expect(DNSName.decoded("한글.local.") == "한글.local")
        #expect(DNSName.decoded("café.local.") == "café.local")
    }

    @Test("A name that composes itself out of format characters survives")
    func keepsJoiners() {
        // The zero-width joiner is a format character like the bidi overrides are, and dropping the
        // category whole took it too: `👨‍💻` came out as `👨💻`, two emoji where the host meant one.
        #expect(DNSName.decoded("\u{1F468}\u{200D}\u{1F4BB}.local.") == "\u{1F468}\u{200D}\u{1F4BB}.local")
        // The non-joiner is ordinary orthography rather than decoration.
        #expect(DNSName.decoded("zero\u{200C}width.local.") == "zero\u{200C}width.local")
        // A subdivision flag is a black flag followed by tag characters spelling the region out.
        // Those are format characters too, so sweeping the category left a plain black flag —
        // and the regional-indicator flags below cannot catch it, having no tag characters.
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        #expect(DNSName.decoded(england + ".local.") == england + ".local")
        // Emoji that need no joiner were never at risk, and neither were the flags.
        #expect(DNSName.decoded("🖨.local.") == "🖨.local")
        #expect(DNSName.decoded("🇯🇵.local.") == "🇯🇵.local")
    }

    @Test("What can end a line or reorder one does not survive")
    func stripsSeparatorsAndBidiControls() {
        // The other half of the rule above: keeping the compositional format characters must not
        // keep the ones a remote host could break or falsify a row with.
        #expect(DNSName.decoded("a\u{2028}b") == "ab")       // line separator
        #expect(DNSName.decoded("a\u{2029}b") == "ab")       // paragraph separator
        #expect(DNSName.decoded("a\u{202E}b") == "ab")       // right-to-left override
        #expect(DNSName.decoded("a\u{2066}b") == "ab")       // first-strong isolate
        #expect(DNSName.decoded("a\u{200F}b") == "ab")       // right-to-left mark
        #expect(DNSName.decoded("a\u{061C}b") == "ab")       // Arabic letter mark
        #expect(DNSName.decoded("a\u{0085}b") == "ab")       // next line, a C1 control
        #expect(DNSName.decoded("a\u{206D}b") == "ab")       // activate Arabic form shaping
        #expect(DNSName.decoded("a\u{206E}b") == "ab")       // national digit shapes
        #expect(DNSName.decoded("a\u{FFFA}b") == "ab")       // interlinear annotation separator
    }

    @Test("An unassigned code point is not something to strip")
    func keepsUnassignedScalars() {
        // `illegalCharacters` used to be in the filter and is not: its contents are whatever the
        // ICU shipped with the running macOS calls unassigned, so on an older one it would swallow
        // every character Unicode has added since. Nothing unassigned can break a row — it draws
        // as a box — which is the whole test.
        let unassigned = "\u{1FADE}"
        #expect(DNSName.decoded("host" + unassigned + ".local.") == "host" + unassigned + ".local")
    }
}
