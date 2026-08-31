#!/usr/bin/env python3
"""Wire the libcurl/OpenSSL + LocalStreamProxy stack into tvold.xcodeproj.

Adds the Swift/C/asm sources to the app target and sets the header/library
search paths, linker flags and bridging header. Idempotent — re-running is a
no-op. Run ON SERV2 (the project lives there).

Usage: python3 add_proxy_stack.py [path/to/project.pbxproj]
"""

import re
import sys

PBXPROJ = sys.argv[1] if len(sys.argv) > 1 else (
    "/Users/srv-admin/Documents/ios6-app/tvold/tvold/tvold.xcodeproj/project.pbxproj")

APP_GROUP = "A34362D42FD764210064ADE1"     # /* tvold */ group
APP_SOURCES = "A34362CE2FD764210064ADE1"   # app target Sources build phase
BUNDLE_ID = "rousseaddict.tvold"           # identifies the app target's configs

# (filename, file type, compiled?) — headers get a file ref but no build entry.
FILES = [
    ("CurlFetcher.swift",        "sourcecode.swift", True),
    ("DebugLog.swift",           "sourcecode.swift", True),
    ("LocalStreamProxy.swift",   "sourcecode.swift", True),
    ("curl_bridge.c",            "sourcecode.c.c",   True),
    ("atomic_stubs.c",           "sourcecode.c.c",   True),
    ("atomic_stubs.S",           "sourcecode.asm",   True),
    ("curl_bridge.h",            "sourcecode.c.h",   False),
    ("tvold-Bridging-Header.h",  "sourcecode.c.h",   False),
]

SETTINGS = {
    "HEADER_SEARCH_PATHS": '"$(SRCROOT)/ThirdParty/curl/include"',
    "LIBRARY_SEARCH_PATHS": '"$(SRCROOT)/ThirdParty/curl/lib"',
    "OTHER_LDFLAGS": '"-lcurl -lssl -lcrypto -lz"',
    "SWIFT_OBJC_BRIDGING_HEADER": '"tvold/tvold-Bridging-Header.h"',
    # Live IPTV keeps playing with the screen locked / app backgrounded.
    "INFOPLIST_KEY_UIBackgroundModes": "audio",
}


def main():
    with open(PBXPROJ) as f:
        src = f.read()

    if "LocalStreamProxy.swift" in src:
        print("already patched — nothing to do")
        return

    build_lines, ref_lines, group_lines, source_lines = [], [], [], []

    for i, (name, ftype, compiled) in enumerate(FILES):
        ref = f"BB20{i:04X}"
        src_id = f"BB21{i:04X}"
        ref_lines.append(
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {ftype}; path = {name}; sourceTree = \"<group>\"; }};")
        group_lines.append(f"\t\t\t\t{ref} /* {name} */,")
        if compiled:
            build_lines.append(
                f"\t\t{src_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
                f"fileRef = {ref} /* {name} */; }};")
            source_lines.append(f"\t\t\t\t{src_id} /* {name} in Sources */,")

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

    # 3. App target Sources build phase
    pat = re.compile(r"(" + APP_SOURCES + r" /\* Sources \*/ = \{.*?files = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(source_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app Sources build phase")

    # 4. Build settings — only the app target's configs (Debug and Release both
    #    carry the app bundle id; the test targets carry their own suffixed ids).
    setting_text = "".join(f"\t\t\t\t{k} = {v};\n" for k, v in SETTINGS.items())
    blocks = re.findall(r"\t\t\w+ /\* \w+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;"
                        r".*?\n\t\t\};\n", src, re.S)
    patched = 0
    for block in blocks:
        if f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};" not in block:
            continue
        new = block.replace("\t\t\tbuildSettings = {\n",
                            "\t\t\tbuildSettings = {\n" + setting_text, 1)
        src = src.replace(block, new, 1)
        patched += 1
    if patched != 2:
        sys.exit(f"ERROR: expected 2 app build configs, patched {patched}")

    with open(PBXPROJ, "w") as f:
        f.write(src)
    print(f"patched: {len(FILES)} files, {len(source_lines)} compiled, "
          f"{patched} build configs")


if __name__ == "__main__":
    main()
