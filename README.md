# Octetly

Octetly is a native macOS LAN scanner built with SwiftUI and AppKit. It discovers hosts with ICMP echo requests and the system ARP cache, then displays addresses, hardware identity, network names, and common remote-access/web ports.

## Run

Requirements: macOS 14 or newer and Swift 6.2.

```sh
swift run Octetly
```

The window is three panes: scan controls on the left, results in the middle, and details on the right for whichever device is selected. Click **Scan** (or press Command-R). The initial scan may trigger macOS's Local Network privacy prompt.

## How a scan runs

Rows appear as they are found rather than at the end. The progress bar tracks discovery, and then the port sweep if one is configured to follow it.

**Discovery** sends ICMP echo requests over a single unprivileged datagram socket, so nothing is forked per address. Addresses, MAC addresses, and vendors are filled in here. It makes three rounds, each re-sending only to the addresses still silent. The first goes out as fast as the socket accepts packets, which a switched LAN handled without measurable loss here; a tunnelled or rate-limited path dropped most of a burst that size, so the later rounds are spread over a few seconds instead. Nothing detects which case you are on — the rounds are what covers both. The spacing is derived from a time budget rather than fixed, since one that suits a `/24` would put a `/16` in the region of ten minutes. Rows from the first round appear in about a second; a `/24` settles in about ten.

**Identification** — reverse DNS and SMB — runs alongside discovery rather than after it, taking each address as it is found and keeping `Device lookups` of them in flight. It has no separate progress phase; names simply fill in, and the status line counts them. Two child processes per host is what the setting is pacing.

**Round-trip times** are measured in a short pass of their own once discovery finishes, over only the hosts that answered. The sweep keeps hundreds of requests outstanding at once, which inflates what comes back, so timing them again with a couple of milliseconds between sends is what makes the Ping column comparable to `ping(8)`. It costs about half a second. `ICMPPinger` carries the measurements behind both of those claims.

**Ports** are last and optional — see Settings below.

`ping(8)` is used instead of the socket only where the socket cannot be opened at all.

## Names and notes

The pencil at the right of the Name column sets a name for a device, and the detail pane on the right takes a free-form note. Both persist across scans and launches, and a name replaces whatever the scan resolved.

Both are filed under the device's MAC address where there is one, so they follow the machine when its address changes. There is none for a host reached through a router or a VPN — nothing on this Mac can see it — so those fall back to being filed under the IP address, and both editors say which of the two is in use. An address-keyed entry follows the address rather than the machine: if DHCP hands that address to something else, the name and note go with it.

Search, at the top right of the list, filters on name, IP address, MAC address, and vendor at once.

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

**Edit Ranges…** saves ranges to scan instead. They persist across launches and accept three forms:

| Form | Example | Addresses |
| --- | --- | --- |
| CIDR network | `192.168.0.0/24` | 192.168.0.1 – 192.168.0.254 |
| Span | `192.168.0.1 - 192.168.31.255` | as written |
| Single address | `192.168.0.42` | one |

A span may be written with `-`, `~`, `〜`, or `～`. Host bits in a CIDR are ignored, so `192.168.0.77/24` means the same network as `192.168.0.0/24`. Network and broadcast addresses are skipped except on a `/31` or `/32`, which have none.

An entered range may hold up to 65,536 addresses — a `/16` is the widest CIDR that fits. Discovery over a `/16` is seconds, but identification and port scanning both scale with how many hosts actually answer.

## Data collected

- IPv4 and neighbor-discovered IPv6 addresses
- MAC address, and the vendor holding that prefix
- round-trip time
- reverse DNS and `.local` mDNS names
- SMB server name and workgroup/domain when advertised
- TCP reachability for SSH (22), HTTP (80), HTTPS (443), and Screen Sharing/VNC (5900)

A MAC address is only available for hosts on a segment this Mac is directly attached to. Anything reached through a router or a VPN has no neighbour-cache entry, so its MAC and vendor are both blank — the same limit any scanner on this machine has.

Vendors come from a bundled copy of the IEEE registries, merged from all three assignment sizes (`MA-L`, `MA-M`, `MA-S`) and matched longest-prefix-first, because the 24-bit row covering a block the IEEE has subdivided names the registration authority rather than the vendor holding the slice. Refresh it with `python3 scripts/update-oui.py`.

An address with the locally administered bit set is reported as `Randomized` rather than as an unknown vendor: no registry ever assigned it. Phones set one per network by default, so this is the usual answer on a Wi-Fi segment.

Octetly runs `/usr/sbin/arp`, `/usr/sbin/ndp`, `/usr/bin/dig`, `/usr/bin/smbutil`, and `/sbin/ping` as a fallback, all included with macOS. It does not send scan results anywhere.
