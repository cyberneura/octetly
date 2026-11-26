# Octetly

A LAN scanner for macOS. SwiftUI + AppKit, a SwiftPM package (one executable).
Swift 6.2 / macOS 14 or later, swiftLanguageModes is .v6 (strict concurrency).

Features and design decisions are written in README.md. Only working procedures live here.

## Build and run

```shell
swift build
swift run Octetly
```

Frequently used tasks are in `.jj-menu.yaml` (open it with `jj-menu`). It also has items that
dump the raw ARP/NDP cache and open the Local Network permission settings.

**`swift build` does not work under the Claude Code sandbox.** SwiftPM compiles the
manifest inside its own `sandbox-exec`, which cannot be nested, so it fails with
`sandbox_apply: Operation not permitted`. Running it with the Bash tool's
`dangerouslyDisableSandbox: true` works (the same applies to `swift test` and launching `.build/debug/Octetly`).

## Tests

`Tests/OctetlyTests/` contains swift-testing tests. They cover the pure logic that interprets
input and the pure functions that decide sweep settings (`ScanRange` / `IPv4` / `IPv6` / `OUIDatabase` /
`NeighbourCache` / `Device` / `DeviceIdentity` / `DeviceExport` / `DNSName` / `SweepProfile` /
`ICMPPinger.sendWindow` / `EchoPinger.reportableRoundTrip`); UI and network I/O are
not included. Only `CommandLineTool` is tested by actually creating links in a temporary folder.
Anything inside `Network/` that does not touch sockets is a test target. Decisions that live
alongside sockets or child processes, where tests cannot reach, should be extracted into pure
functions before they are written.

```shell
swift test
```

This is also the gatekeeper for release builds (the test job in `.github/workflows/release.yml`).
Deleting tests, or leaving them failing, makes it impossible to ship a release.

There is no way to verify code that touches the UI or the network from `swift test`. When you
want to try the logic of a single file locally, you can also pass the target sources directly to
`swiftc` and compile them together with a scratch harness.

```shell
swiftc -swift-version 6 -o /tmp/check \
  Sources/octetly/Network/IPv4.swift Sources/octetly/Network/ScanRange.swift \
  <harness>/main.swift
```

Files that reference bundled resources (check with `grep -rn 'BundledResource' Sources/`) do
not compile this way. Make a copy with just that function removed, or leave the file out.

For type-checking the whole source tree only, adding a stub for `Bundle.module` and passing it to
`-typecheck` works even inside the sandbox. The module cache cannot be written to its default
location, so specify one.

```shell
echo 'import Foundation; extension Bundle { static let module = Bundle.main }' > "$TMPDIR/stub.swift"
swiftc -typecheck -swift-version 6 -target arm64-apple-macosx14.0 -parse-as-library \
  -module-cache-path "$TMPDIR/modcache" -Xcc -fmodules-cache-path="$TMPDIR/modcache" \
  $(find Sources/octetly -name '*.swift') "$TMPDIR/stub.swift"
```

Only the expansion of `@Observable` fails, because `swift-plugin-server` cannot nest sandbox-exec.
The three kinds of error that follow from it can be ignored: `external macro implementation type ... could not be found`,
`The wrapped value must be an object that conforms to Observable` at places that wrap that type in
`@State` / `@Bindable`, and `couldn't create cache file ... xcrun_db`. If there are 0 errors other
than those, it passes.

### Checking the UI

Measure UI behaviour such as layout and selection numerically from the running app. Add a
temporary `.task` to `ContentView` that is enabled by an environment variable, run `scanner.scan()` →
wait a few seconds → find the `NSTableView` in `NSApp.windows`, and `NSLog` `rect(ofRow:)` or the
frames of the view hierarchy. The hover state of the copy button can be reproduced by calling
`copier.pointer(isInside:_:)` directly (the pencil in the Name column is `@State` inside the cell, so
it does not appear). **Measure on rows where the condition you are verifying actually holds**
(for the copy button, rows that have a name or address). Measuring on rows where the condition does
not hold lets the check pass without showing any difference.

For screenshots, call `cacheDisplay(in:to:)` per window inside the same `.task` and write PNGs. Sheets
can also be captured as separate windows. Do not use `screencapture -l <window number>`, which fails
while a sheet is shown, nor fall back to `screencapture` without arguments, which also captures other apps.

`@AppStorage` under `swift run` is written to the domain `Octetly` (`defaults read Octetly`). These are
the same settings as the app the user runs with `swift run`, so restore any values you changed while
verifying (the distributed .app uses `com.cyberneura.octetly`, which is separate). Remove the debug
`.task` before committing.

### A/B measurements

When A/B testing network measurements, **insert a cool-down between runs**. Running sweeps back to back
gets them throttled along the path, and the detection count fluctuates independently of the
conditions, so the comparison is meaningless. Judge by comparing against a parallel `ping` sweep run
at the same time.

## Distribution

What `swift run` / `swift build` produce is not a .app bundle. The distributed .app is assembled by
`scripts/make-app.sh` (universal binary + resources + size-specific icon.icns / Assets.car + `packaging/Info.plist`). The dmg is made by `scripts/make-dmg.sh`. Signing and notarization are done by
`.github/workflows/release.yml`; locally you get an unsigned .app.

The version comes from **one source: the `VERSION` file at the repository root**. make-app.sh fills
`CFBundleShortVersionString` in `Info.plist` from it.

### Reference resources through `BundledResource`

**Do not call `Bundle.module` directly.** The accessor SwiftPM generates looks for the resource
bundle directly under `Bundle.main.bundleURL` (= directly under `Octetly.app/`).
Nothing other than `Contents` can be placed at the top level of a .app (doing so breaks the
signature), so in the bundled build there is no way to put it there. **When it is not found the
accessor calls `fatalError` rather than returning nil, so naive code makes the distributed build
crash on launch.**

For that reason make-app.sh expands the contents of the resource bundle into `Contents/Resources`,
and `BundledResource.url(forResource:withExtension:)` looks in the .app (`BundledResource.app`,
normally `Bundle.main`) first and in `Bundle.module` second. Under `swift run` the former misses and
the latter hits.

There are other places where **behaviour differs between the bundled build and `swift run`**
(`applyDockIcon` in `OctetlyApp.swift` branches on whether there is an Info.plist).
Do not land changes that have been checked in only one of them.

There is one more launch mode. **Via `/usr/local/bin/octetly` (a symbolic link) created by
Install Command-Line Tool…**, `Bundle.main` becomes the folder containing the link, and there is
neither an Info.plist nor resources. When reading the contents of the .app, use `BundledResource.app`
(the .app with the link resolved). To check, create a link to a .app built by `scripts/make-app.sh`
and run `version` / `--license` through it.

## Command line

There is a single executable; `OctetlyMain` (`@main`) inspects the arguments and dispatches to the
GUI or the CLI (`octetly lookup` / `octetly search`). **`CLICommand.parse` returns nil for unknown
arguments and opens the GUI.** This is so that launches with `-psn_…` / `-NSDocumentRevisionsDebugMode`,
which macOS and Xcode add, do not fail; do not change it to "unknown arguments are an error".
The parser is tested by `CLICommandTests`.

## Generated data

`Sources/octetly/Resources/oui.csv` is generated by merging IEEE's three registries
(54k lines). Do not edit it by hand. To update it:

```shell
python3 scripts/update-oui.py
```

Exclude it from reviews and code reading.

## License notices

`LICENSE` (MIT) and `THIRD-PARTY-NOTICES.txt` are at the repository root, and the app carries
copies of them (`Sources/octetly/Resources/LICENSE.txt` / `THIRD-PARTY-NOTICES.txt`) as
resources. **Third-Party Licenses…** directly under About in the app menu and
`octetly --license` display them (`Licenses.swift`).

**Do not edit any of them by hand.** When you add a dependency to `Package.swift` or change
`LICENSE`, rerun the following and commit the three generated files.

```shell
scripts/generate-third-party-notices.sh
```

There are no dependencies right now, so it only writes the boilerplate "no bundled libraries", and
it stops with an error when a `.package(...)` appears. When adding a dependency, extend the script to
include the pins from `Package.resolved` and the text of `.build/checkouts/*/LICENSE*`
(resolving only works on macOS). Leaving the files stale makes the release.yml test job
(`--check`) and `LicenseTests` fail.

## Issue tracking

`_issues/<YYYYMMDD>-<summary>/ISSUE.md`. It is listed in `.gitignore`, so it is not committed.

## macOS app icon

Run `bash scripts/generate-macos-icons.sh` with Xcode on macOS. Fixed artwork,
layout measurements, size-specific sources and the verification command are in
`resources/app-icons/README.md`. Small @1x backgrounds reach the canvas edges;
the glyph fits inside the central 80%. Larger backgrounds have 10% outer margins.
Do not replace the generated ICNS with `tauri icon` / `iconutil`: preserve the
ARGB small entries and the matching Assets.car / CFBundleIconName registration.
Native rendering is verified by `.github/workflows/macos-icons.yml`.
