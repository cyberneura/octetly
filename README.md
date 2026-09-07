# Octetly

Octetly is a native macOS LAN scanner built with SwiftUI and AppKit. It finds hosts with ICMP echo requests, ICMPv6 to the all-nodes multicast group, and the system ARP cache, fills in further addresses from the NDP cache, and displays addresses, hardware identity, network names, and common remote-access/web ports.

## Install

```sh
brew install --cask cyberneura/tap/octetly
```

A universal build (Intel and Apple Silicon), signed with a Developer ID and notarized.

## Run from source

Requirements: macOS 14 or newer and Swift 6.2.

```sh
swift run Octetly
```

`swift run` produces a bare executable rather than an app bundle, which is enough to
use but is not what is released. `scripts/make-app.sh` builds `dist/Octetly.app`: the
universal binary, the resource bundle, an icon, and the `Info.plist` in `packaging/`.

The window is three panes: scan controls on the left, results in the middle, and details on the right for whichever device is selected. Click **Scan** (or press Command-R). The initial scan may trigger macOS's Local Network privacy prompt.

## How a scan runs

Rows appear as they are found rather than at the end. The progress bar follows each phase in turn — discovery, the round-trip timing after it, the IPv6 sweep, and the port sweep if one is configured to follow.

**Discovery** sends ICMP echo requests over a single unprivileged datagram socket, so nothing is forked per address. Addresses, MAC addresses, and vendors are filled in here. How it paces those requests depends on where the target is, because the two cases differ by an order of magnitude.

A range gets up to three rounds, each re-sending only to the addresses still silent and the lot stopping early once none are; what changes is how fast the requests leave. A range inside this Mac's own subnet sends the first round as fast as the socket accepts packets — a switched LAN handled that without measurable loss here. A range reached through a router or a tunnel drops the burst and spaces every round out, asking for up to 25 ms between sends — a little over that in practice, since macOS rounds a sleep up, and more again where one window of them ends and the next begins, which is where the replies are read. That second setting comes from one VPN-routed path and is applied to every routed range, since nothing here measures a path before choosing: a fast router pays for it in time it did not need to spend. Over a VPN-routed `/24` whose hosts each answer `ping(8)` with no loss when probed on their own, the two settings found 13 hosts and 23 for roughly twice the time; adding rounds at the LAN spacing did not close that gap and slowing the send did, so what is being hit there is a rate limit rather than a timeout. The burst is worse than useless on such a path — one measured pass of it reached 2 of the 16 hosts then known, having spent its full reply window to do so. A range with any part of it outside the subnet counts as routed for the whole of itself, since there is one profile per scan. The test is one interface's subnet rather than the routing table, so it can be wrong both ways: a VPN route covering part of the LAN it was dialled in from reads as on-link, and a second interface's own subnet reads as routed, because only the first interface found is consulted. Neither mistake costs a host an attempt — both profiles ask a silent address three times — but they are not equivalent, and neither is free. Reading a routed path as on-link puts a burst on it, which is the 13-against-23 above: the faster scan and the one that loses hosts. Reading an on-link range as routed spends time, and leaves the Ping column blank for a host slow enough to answer discovery but not the timing pass, since the same choice decides whether an unconfirmed round-trip time is kept. Spacing also changes *when* an address is asked: the last one in a paced `/24` goes out about 7 s into the round rather than within 11 ms, so a host reachable only for the first instant of a scan is one a burst would have caught.

The spacing is capped by a time budget rather than fixed, and on a wide range the budget is the only thing setting it — 25 ms would put a `/16` at about half an hour a round. Through a router that budget holds the full 25 ms out to 1,040 addresses, so every range up to a `/22` gets the spacing the figures above were measured at: about 7 s of sending a round for a `/24` and 29 s for a `/22`, which with the reply waits is about 9 s and 32 s a round. Past a `/22` the gap falls below what was measured to work, and there is nothing else to offer. A `/24` settles in about ten seconds on a LAN and about half a minute through a tunnel.

**Identification** — reverse DNS, mDNS, and SMB — runs alongside discovery rather than after it, taking each address as it is found and keeping `Device lookups` of them in flight. It has no separate progress phase; names simply fill in, and the status line counts them. The setting counts hosts, not processes: a host runs three lookups — reverse DNS, mDNS, SMB — as two child processes at a time, so `Device lookups` of 24 is up to 48 of them at once.

The mDNS query is asked of the host directly, on its own port 5353, rather than through the system resolver. The resolver does answer for `.local`, but the query it sends is multicast, and multicast does not cross a router — let alone a point-to-point tunnel. Asking the host itself reaches past both, and it is where most names actually come from: on the routed `/24` above, `dig`, `dscacheutil` and `host` returned nothing for any address they were tried on, while a scan of that range named 8 hosts this way, and on this Mac's own LAN the `.local` names on IPv4 rows come from it too. It is not guaranteed to work through a router, though — RFC 6762 §5.5 says a responder *should* ignore a unicast query whose source is not on one of its own subnets, which through a tunnel is exactly what this is. No responder met on any path measured here did that check; one that does costs the query a second and leaves the row to whatever else answered. A row with no IPv4 address is the exception to all of this: it cannot exist until the IPv6 phase has run, so it joins the queue at the end, and it is named by one in-process `getnameinfo`.

**Round-trip times** are measured in a pass of their own once discovery finishes, over only the hosts that answered. The sweep keeps the path loaded while it is still sending, which inflates what comes back, so timing them again with gaps between sends is what makes the Ping column comparable to `ping(8)`. It costs about half a second on a LAN. A routed path is spaced at 25 ms like its discovery and goes back a second time, first listening out the window the last round gave up on — a reply that arrives then is timed against the send it answers, where one arriving after the next send would be timed against that and read as a fraction of what it was — and then re-probing whichever hosts are still without a figure. A host that misses every round is left blank rather than shown the reading discovery took mid-sweep, which for hosts that answer in 25 ms was measured at 600 to 1,060. This pass is proportional to how many hosts answered rather than to the range, so it carries a time budget of its own for the case where that is hundreds.

A figure is refused outright once it exceeds the longest wait any sweep here makes. Replies are matched to sends by address, so a reply nobody is waiting for any more still lands against whatever was last sent there, and how wrong that can get is set by how long the send loop runs: a burst puts every send within about 11 ms of every other, while a paced pass spends seconds in the loop. Left unbounded, one host that `ping(8)` answers in 80 ms reached the Ping column at 16,419.9 ms — the duration of the sweep, reported as a round trip. Such a row still counts as having answered; only the number is dropped. `ICMPPinger` and `EchoPinger` carry the measurements behind all of this.

**IPv6** comes after the IPv4 half rather than beside it. One ICMPv6 echo request to `ff02::1`, the all-nodes multicast group, reaches every IPv6 node on the segment for the cost of a single packet, and a node that answers does so from its own address — including hosts that ignored every IPv4 request, and hosts that have no IPv4 address to have been asked at. Answering is a SHOULD in RFC 4443 rather than a MUST, so silence is not proof of absence. Five rounds a second apart, because a round keeps paying for longer than it looks like it should: left to run, the rounds added 55, +5, +1, +1, +1, +0.

The neighbour cache is read after that sweep rather than before it: a run that read it first left 3 of its 57 replies with no hardware address to match on, and a run that read it afterwards had one for all 63. Those are two runs against a moving network, so they settle which order to prefer and not the mechanism behind it. That hardware address is what folds a reply into the row the IPv4 sweep already made for the same machine. A reply the cache has no entry for is still taken at face value and gets a row — losing it would lose the one kind of host this sweep exists to find. A read of the cache that did not *finish* is refused outright, though: half a table would answer "nothing else has seen this machine" for every host the read stopped short of, which is one duplicate row each. A table that comes back empty is refused on the same reasoning — hosts answered this segment a moment ago, and a cache holding nothing for the interface they answered on is one that cannot be matched against at all.

No round-trip time comes out of the multicast rounds, and none would be worth showing: the replies to one request were measured spread between 0.3 ms and over 100 ms from hosts that answer a unicast request in single-digit milliseconds, and what that spread is made of — a delay the host inserted, a wireless duty cycle, a queue — is not something a scanner can tell apart. The rows with no IPv4 address are timed in a spaced unicast pass of their own instead, on its own socket, at the address they answered from rather than at whichever of their addresses reads best. They are named through `getnameinfo`, which asks mDNSResponder — `dig -x` cannot name a link-local address, because no `ip6.arpa` delegation for one exists to be found.

**Ports** are last and optional — see Settings below. A host with no IPv4 address is scanned over IPv6, zone and all.

`ping(8)` is used instead of the socket only where the socket cannot be opened at all.

## Hosts that answer nothing

A machine that filters ICMP is still on the list. Sending an echo request makes the kernel resolve the address first, and that resolution is answered underneath whatever is dropping the ping, so the ARP cache holds an entry for a host that never replied to the ping itself. 20 and 21 of about 125 rows came from there across two runs on the network this was written on — though not all of them are necessarily machines filtering ICMP, for the reason two paragraphs down.

The detail pane's **Seen by** line says which mechanisms account for each row, because nothing else on the row does — a blank Ping column is equally what a host that answered late looks like.

The two caches do not have the same standing, and what decides it is what this scan does rather than what the two protocols offer. The sweep sends to every address in the range, so every ARP entry inside it has just been asked a question, and `arp -anl` says whether an answer came back — `Expire(O)` counts from this Mac's last **send** to that address, `Expire(I)` from the last packet **received**. Only the second is about the host. Across one sweep, in-range entries went from 89 with both sides expired to 132 with both live; the four that came out live outbound and still expired inbound had been swept and answered nothing, and those are the ones dropped. Plain `arp -an` prints all of these identically, which is why the `-l` form is the one parsed.

That test is narrower than it sounds, because the inbound timer is kept per hardware address rather than per entry — eight rows sharing one NIC here all read the same value. A host that changed address keeps a live timer on its old row for as long as the same NIC answers at the new one, so that ghost stays; and a host that changed NIC without changing address is dropped, because the kernel spends the sweep unicasting to the MAC it already has and never reaches it. Neither is distinguishable from a machine that left. It only ever decides rows nothing else found: an address that answered an echo request is on the list from that alone.

Nothing sends to the NDP entries individually before that table is read — the IPv6 probe goes to the group — so none of this applies to them. IPv6 has the same machinery, and `ndp -an` would show a stale neighbour moving through DELAY and PROBE if anything unicast to it; the timing pass and the port scan do, but both run after the table has been read and only reach rows a reply already established. So at the moment it is read, an NDP entry sits at whatever it was, and it sits there a long time.

`ndp -an` here lists neighbours expiring in just under 24 hours, long enough that a laptop taken home yesterday would still read as present today. So the NDP cache only ever adds addresses to rows that something else established, and every row that exists because of IPv6 exists because the host answered a probe during this scan.

## Names and notes

The pencil at the right of the Name column sets a name for a device, and the detail pane on the right takes a free-form note. Both persist across scans and launches, and a name replaces whatever the scan resolved.

Both are filed under the device's MAC address where there is one, so they follow the machine when its address changes. Two kinds of row have none: a host reached through a router or a VPN, which nothing on this Mac can see a hardware address for, and one that answered the IPv6 all-nodes probe without the neighbour cache holding an entry for it. Both fall back to the address the row was created at, and both editors say which key is in use. An address-keyed entry follows the address rather than the machine: if DHCP hands that address to something else, the name and note go with it.

Search, in the title bar, filters on name, IP address, MAC address, and vendor at once.

## Settings

In the left pane, and under Command-comma:

| Setting | Default | Effect |
| --- | --- | --- |
| Device lookups | 24 | Hosts named in parallel. Discovery is not paced by this — echo requests cost a packet, not a process. |
| Port scan | When a device is selected | `Never`, `When a device is selected`, or `After the scan finishes`. |
| Port scan sockets | 24 | Connection attempts in flight during the after-scan sweep. Each host uses one socket per port. |

A port that is firewalled answers nothing, so it costs the full 0.6 s timeout. Scanning every host found on a busy `/24` therefore adds several seconds, which is why the default waits until a device is actually selected.

Selecting a device scans that one host, and selecting another cancels the first, so `Port scan sockets` has nothing to pace in that mode — it applies to `After the scan finishes`.

## Scan ranges

The **Target** picker chooses what to scan. **Automatic** uses the network this Mac is attached to, capped at 1,024 addresses so that being on an enterprise or VPN segment does not turn a plain Scan into a sweep of it.

Target bounds the IPv4 half only. `ff02::1` names the segment this Mac is attached to and nothing narrower, so a host that answers there is listed whatever the target says — narrowing the target to a `/24` does not narrow the IPv6 sweep to the hosts inside it.

**Edit Ranges…** saves ranges to scan instead. They persist across launches and accept three forms:

| Form | Example | Addresses |
| --- | --- | --- |
| CIDR network | `192.168.0.0/24` | 192.168.0.1 – 192.168.0.254 |
| Span | `192.168.0.1 - 192.168.31.255` | as written |
| Single address | `192.168.0.42` | one |

A span may be written with `-`, `~`, `〜`, or `～`. Host bits in a CIDR are ignored, so `192.168.0.77/24` means the same network as `192.168.0.0/24`. Network and broadcast addresses are skipped except on a `/31` or `/32`, which have none.

An entered range may hold up to 65,536 addresses — a `/16` is the widest CIDR that fits. What discovery over one costs depends on which side of this Mac's own subnet it falls: inside it, about fifteen seconds; outside, up to about a minute and three quarters, because the send budget gives each of the three rounds 26 s of gaps to spend and macOS rounds gaps that small up by more than a quarter, to about 33. Identification and port scanning scale with how many hosts actually answer rather than with the range.

## Data collected

- IPv4 and IPv6 addresses — every address the neighbour cache has against a host's NIC, routable ones first; more than one link-local address is ordinary rather than a fault, in a cache that keeps entries for most of a day
- what the row was seen by: ICMP echo, ICMPv6 echo, the ARP cache, the NDP cache — the last of which never creates a row, only adds addresses to one
- MAC address, and the vendor holding that prefix
- round-trip time
- reverse DNS and `.local` mDNS names
- SMB server name and workgroup/domain when advertised
- TCP reachability for SSH (22), HTTP (80), HTTPS (443), and Screen Sharing/VNC (5900)

A MAC address is only available for hosts on a segment this Mac is directly attached to. Anything reached through a router or a VPN has no neighbour-cache entry, so its MAC and vendor are both blank — the same limit any scanner on this machine has.

Vendors come from a bundled copy of the IEEE registries, merged from all three assignment sizes (`MA-L`, `MA-M`, `MA-S`) and matched longest-prefix-first, because the 24-bit row covering a block the IEEE has subdivided names the registration authority rather than the vendor holding the slice. Refresh it with `python3 scripts/update-oui.py`.

An address with the locally administered bit set is reported as `Randomized` rather than as an unknown vendor: no registry ever assigned it. Phones set one per network by default, so this is the usual answer on a Wi-Fi segment.

Octetly runs `/usr/sbin/arp`, `/usr/sbin/ndp`, `/usr/bin/dig`, `/usr/bin/smbutil`, and `/sbin/ping` as a fallback, all included with macOS. It does not send scan results anywhere.

## Releases

A release is decided by the `VERSION` file on `main`: change it and
`.github/workflows/release.yml` builds that version, signs and notarizes it, and puts
the dmg on a GitHub Release. Leave it and pushing changes nothing, so what decides is
not the diff but whether that version has been released already.

```sh
scripts/release.sh          # patch
scripts/release.sh minor
scripts/release.sh major
```

The script only runs from a clean `main` that matches `origin/main`. It writes the new
number to `VERSION`, pushes, and watches the run that starts.

The Homebrew cask lives in [cyberneura/homebrew-tap](https://github.com/cyberneura/homebrew-tap)
and points itself at the newest release once an hour, so `brew` is up to an hour behind
a release.
