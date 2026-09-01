#!/usr/bin/env python3
"""Rebuilds Sources/octetly/Resources/oui.csv from the IEEE registries.

Three registries are merged because a vendor may hold a whole 24-bit block (MA-L) or a slice of
one (MA-M, MA-S). The MA-L row covering a sliced block names the IEEE itself rather than the
vendor, so the lookup has to prefer the longest matching prefix and the file has to carry all
three lengths for it to have anything to prefer.

Commas are stripped from vendor names so the file needs no quoting rules to read back.

    python3 scripts/update-oui.py
"""

import csv
import io
import pathlib
import re
import sys
import urllib.request

REGISTRIES = [
    ("https://standards-oui.ieee.org/oui/oui.csv", 6),
    ("https://standards-oui.ieee.org/oui28/mam.csv", 7),
    ("https://standards-oui.ieee.org/oui36/oui36.csv", 9),
]

DESTINATION = pathlib.Path(__file__).resolve().parent.parent / "Sources/octetly/Resources/oui.csv"
MAX_NAME = 48


def clean(name):
    name = re.sub(r"\s+", " ", name).strip().strip('"')
    name = name.replace(",", " ")
    name = re.sub(r"\s+", " ", name).strip()
    return name[:MAX_NAME].strip()


def fetch(url, width):
    # The registry answers 418 to urllib's default User-Agent.
    request = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(request, timeout=180) as response:
        text = response.read().decode("utf-8", errors="replace")
    rows = {}
    for row in csv.DictReader(io.StringIO(text)):
        assignment = (row.get("Assignment") or "").strip().upper()
        organization = clean(row.get("Organization Name") or "")
        if len(assignment) != width or not organization:
            continue
        if not all(character in "0123456789ABCDEF" for character in assignment):
            continue
        rows[assignment] = organization
    return rows


def main():
    entries = {}
    for url, width in REGISTRIES:
        try:
            rows = fetch(url, width)
        except Exception as error:  # noqa: BLE001 - the URL and the reason both matter here
            print(f"failed: {url}: {error}", file=sys.stderr)
            return 1
        print(f"{url} -> {len(rows)} entries of {width} hex digits")
        entries.update(rows)

    with DESTINATION.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("prefix,vendor\n")
        for prefix in sorted(entries):
            handle.write(f"{prefix},{entries[prefix]}\n")

    print(f"wrote {DESTINATION} with {len(entries)} entries "
          f"({DESTINATION.stat().st_size / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
