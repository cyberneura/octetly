# Octetly

Octetly is a native macOS LAN scanner built with SwiftUI and AppKit. It discovers hosts with ICMP echo requests and the system ARP cache, then displays addresses, hardware identity, network names, and common remote-access/web ports.

## Run

Requirements: macOS 14 or newer and Swift 6.3.

```sh
swift run Octetly
```

Click **Scan** (or press Command-R). The initial scan may trigger macOS's Local Network privacy prompt. Scanning a typical `/24` takes several seconds; Octetly caps unusually large segments at 1,024 addresses to avoid an accidental enterprise or VPN sweep.

## Data collected

- IPv4 and neighbor-discovered IPv6 addresses
- MAC address and vendor from the bundled OUI prefix table
- reverse DNS and `.local` mDNS names
- SMB server name and workgroup/domain when advertised
- TCP reachability for SSH (22), HTTP (80), HTTPS (443), and Screen Sharing/VNC (5900)

Octetly runs `/sbin/ping`, `/usr/sbin/arp`, `/usr/sbin/ndp`, `/usr/bin/dig`, and `/usr/bin/smbutil`, all included with macOS. It does not send scan results anywhere.
