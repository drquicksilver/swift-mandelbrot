#!/usr/bin/env python3
"""Merge the compiler's extracted strings into Mandelbrot/Localizable.xcstrings.

Xcode keeps a string catalogue in step with the code when it builds in the IDE;
`xcodebuild` extracts the strings but never writes them back.  This does that
step from the command line: it reads every `.stringsdata` the Mac and iOS builds
left behind, adds keys the catalogue lacks, marks keys the code no longer uses
as stale if they were translated (and drops them if not), and keeps whatever
translations are already there.

    python3 tools/update_strings.py BUILD_DIR [BUILD_DIR ...]
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "Mandelbrot" / "Localizable.xcstrings"


def extracted(build_dirs):
    keys = {}
    for build in build_dirs:
        for path in pathlib.Path(build).rglob("*.stringsdata"):
            data = json.loads(path.read_text())
            for entry in data.get("tables", {}).get("Localizable", []):
                key = entry["key"]
                # A bare format such as "%@" is data, not copy.
                if not re.search(r"[A-Za-z]", re.sub(r"%(\d+\$)?[@dfslu]|%ll[du]", "", key)):
                    continue
                comment = entry.get("comment") or ""
                keys.setdefault(key, comment)
    return keys


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    found = extracted(sys.argv[1:])
    if not found:
        sys.exit("No extracted strings: build the app first (make build ios).")
    catalogue = (
        json.loads(CATALOGUE.read_text())
        if CATALOGUE.exists()
        else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    )
    strings = catalogue["strings"]
    for key, comment in found.items():
        entry = strings.setdefault(key, {})
        entry.pop("extractionState", None)
        if comment:
            entry["comment"] = comment
    for key in [key for key in strings if key not in found]:
        # A retired string with no translation is simply gone; one that was
        # translated is kept, marked stale, for a person to decide about.
        if strings[key].get("localizations"):
            strings[key]["extractionState"] = "stale"
        else:
            del strings[key]
    catalogue["strings"] = dict(sorted(strings.items(), key=lambda item: item[0].lower()))
    CATALOGUE.write_text(json.dumps(catalogue, indent=2, ensure_ascii=False) + "\n")
    stale = sum(1 for entry in strings.values() if entry.get("extractionState") == "stale")
    print(f"{len(found)} strings, {stale} stale, in {CATALOGUE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
