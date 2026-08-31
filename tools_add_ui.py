#!/usr/bin/env python3
"""Wire the tvold player UI into tvold.xcodeproj.

Adds the UI Swift sources to the app target, adds the generated channel index
as a bundled folder reference, and drops the spike's ViewController.swift.

The index goes in as a *folder reference* (lastKnownFileType = folder), not as
178 individual file references — the whole point of the per-country split is
that the app opens one file at a time, and a folder reference gets copied into
the bundle verbatim so ChannelIndex can read Resources/index/<cc>.json.

Idempotent — re-running is a no-op. Run ON SERV2 (the project lives there).

Usage: python3 add_ui.py [path/to/project.pbxproj]
"""

import re
import sys

PBXPROJ = sys.argv[1] if len(sys.argv) > 1 else (
    "/Users/srv-admin/Documents/ios6-app/tvold/tvold/tvold.xcodeproj/project.pbxproj")

APP_GROUP = "A34362D42FD764210064ADE1"      # /* tvold */ group
APP_SOURCES = "A34362CE2FD764210064ADE1"    # app target Sources build phase
APP_RESOURCES = "A34362D02FD764210064ADE1"  # app target Resources build phase
OLD_VC_REF = "A34362D52FD764210064ADE1"     # ViewController.swift (the spike)
OLD_VC_BUILD = "A34362D62FD764210064ADE1"

SOURCES = [
    "ChannelIndex.swift",
    "Favorites.swift",
    "LogoCache.swift",
    "CountriesViewController.swift",
    "ChannelListViewController.swift",
    "PlayerViewController.swift",
]
INDEX_FOLDER = "index"


def main():
    with open(PBXPROJ) as f:
        src = f.read()

    if "PlayerViewController.swift" in src:
        print("already patched — nothing to do")
        return

    build_lines, ref_lines, group_lines, source_lines = [], [], [], []

    for i, name in enumerate(SOURCES):
        ref, bid = f"BB30{i:04X}", f"BB31{i:04X}"
        ref_lines.append(
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
        group_lines.append(f"\t\t\t\t{ref} /* {name} */,")
        build_lines.append(
            f"\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};")
        source_lines.append(f"\t\t\t\t{bid} /* {name} in Sources */,")

    idx_ref, idx_build = "BB3000FF", "BB3100FF"
    ref_lines.append(
        f"\t\t{idx_ref} /* {INDEX_FOLDER} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = folder; path = {INDEX_FOLDER}; sourceTree = \"<group>\"; }};")
    group_lines.append(f"\t\t\t\t{idx_ref} /* {INDEX_FOLDER} */,")
    build_lines.append(
        f"\t\t{idx_build} /* {INDEX_FOLDER} in Resources */ = {{isa = PBXBuildFile; "
        f"fileRef = {idx_ref} /* {INDEX_FOLDER} */; }};")

    # 1. PBXBuildFile + PBXFileReference sections
    src = src.replace("/* End PBXBuildFile section */",
                      "\n".join(build_lines) + "\n/* End PBXBuildFile section */", 1)
    src = src.replace("/* End PBXFileReference section */",
                      "\n".join(ref_lines) + "\n/* End PBXFileReference section */", 1)

    # 2. App group children
    pat = re.compile(r"(" + APP_GROUP + r" /\* \w+ \*/ = \{.*?children = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(group_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app group's children list")

    # 3. Sources and Resources build phases
    pat = re.compile(r"(" + APP_SOURCES + r" /\* Sources \*/ = \{.*?files = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(source_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app Sources build phase")

    pat = re.compile(r"(" + APP_RESOURCES + r" /\* Resources \*/ = \{.*?files = \(\n)", re.S)
    src, n = pat.subn(
        lambda m: m.group(1) + f"\t\t\t\t{idx_build} /* {INDEX_FOLDER} in Resources */,\n",
        src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app Resources build phase")

    # 4. Drop the spike view controller — CountriesViewController is the root now.
    dropped = 0
    for uuid in (OLD_VC_REF, OLD_VC_BUILD):
        src, k = re.subn(r"^\t+" + uuid + r" .*\n", "", src, flags=re.M)
        dropped += k
    if dropped != 4:  # 1 build entry + 1 file ref + 1 group child + 1 sources entry
        sys.exit(f"ERROR: expected 4 ViewController.swift lines to remove, removed {dropped}")

    with open(PBXPROJ, "w") as f:
        f.write(src)
    print(f"patched: {len(SOURCES)} sources, index folder reference, "
          f"{dropped} ViewController.swift lines removed")


if __name__ == "__main__":
    main()
