#!/usr/bin/env python3
"""Add Swift sources to the tvold app target.

Generic replacement for the one-off add_proxy_stack.py / add_ui.py scripts:
takes filenames on the command line, derives stable UUIDs from the names (so
re-running is a no-op rather than a duplicate), and wires each file into both
the app group and the Sources build phase.

Idempotent. Run ON SERV2 (the project lives there).

Usage: python3 add_files.py Foo.swift Bar.swift [--pbxproj PATH]
"""

import hashlib
import re
import sys

DEFAULT_PBXPROJ = (
    "/Users/srv-admin/Documents/ios6-app/tvold/tvold/tvold.xcodeproj/project.pbxproj")

APP_GROUP = "A34362D42FD764210064ADE1"    # /* tvold */ group
APP_SOURCES = "A34362CE2FD764210064ADE1"  # app target Sources build phase


def uuid(prefix, name):
    return prefix + hashlib.md5(name.encode()).hexdigest()[:9].upper()


def main():
    args = sys.argv[1:]
    pbxproj = DEFAULT_PBXPROJ
    if "--pbxproj" in args:
        i = args.index("--pbxproj")
        pbxproj = args[i + 1]
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)

    with open(pbxproj) as f:
        src = f.read()

    todo = [n for n in args if n not in src]
    skipped = [n for n in args if n in src]
    for n in skipped:
        print(f"already present, skipping: {n}")
    if not todo:
        return

    build_lines, ref_lines, group_lines, source_lines = [], [], [], []
    for name in todo:
        ref, bid = uuid("BB4", name), uuid("BB5", name)
        ref_lines.append(
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
        group_lines.append(f"\t\t\t\t{ref} /* {name} */,")
        build_lines.append(
            f"\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};")
        source_lines.append(f"\t\t\t\t{bid} /* {name} in Sources */,")

    src = src.replace("/* End PBXBuildFile section */",
                      "\n".join(build_lines) + "\n/* End PBXBuildFile section */", 1)
    src = src.replace("/* End PBXFileReference section */",
                      "\n".join(ref_lines) + "\n/* End PBXFileReference section */", 1)

    pat = re.compile(r"(" + APP_GROUP + r" /\* \w+ \*/ = \{.*?children = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(group_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app group's children list")

    pat = re.compile(r"(" + APP_SOURCES + r" /\* Sources \*/ = \{.*?files = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(source_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app Sources build phase")

    with open(pbxproj, "w") as f:
        f.write(src)
    print("added: " + ", ".join(todo))


if __name__ == "__main__":
    main()
