#!/usr/bin/env python3
"""Add files to the tvold app target.

Generic replacement for the one-off add_proxy_stack.py / add_ui.py scripts:
takes filenames on the command line, derives stable UUIDs from the names (so
re-running is a no-op rather than a duplicate), and wires each file into both
the app group and a build phase.

Idempotent. Run ON SERV2 (the project lives there).

Usage: python3 add_files.py Foo.swift Bar.swift [--pbxproj PATH]
       python3 add_files.py --resources Icons/Icon-57.png ...

A path may be relative to the group (Icons/Icon-57.png). The copy-resources
phase flattens what it copies, so an icon kept in a subfolder on disk still
lands at the bundle root, which is where iOS looks for it.
"""

import hashlib
import re
import sys

DEFAULT_PBXPROJ = (
    "/Users/srv-admin/Documents/ios6-app/tvold/tvold/tvold.xcodeproj/project.pbxproj")

APP_GROUP = "A34362D42FD764210064ADE1"      # /* tvold */ group
APP_SOURCES = "A34362CE2FD764210064ADE1"    # app target Sources build phase
APP_RESOURCES = "A34362D02FD764210064ADE1"  # app target Resources build phase

FILE_TYPES = {".swift": "sourcecode.swift", ".png": "image.png"}


def uuid(prefix, name):
    return prefix + hashlib.md5(name.encode()).hexdigest()[:9].upper()


def main():
    args = sys.argv[1:]
    pbxproj = DEFAULT_PBXPROJ
    if "--pbxproj" in args:
        i = args.index("--pbxproj")
        pbxproj = args[i + 1]
        del args[i:i + 2]
    resources = "--resources" in args
    if resources:
        args.remove("--resources")
    phase, phase_name = ((APP_RESOURCES, "Resources") if resources
                         else (APP_SOURCES, "Sources"))
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

    build_lines, ref_lines, group_lines, phase_lines = [], [], [], []
    for name in todo:
        ref, bid = uuid("BB4", name), uuid("BB5", name)
        ext = name[name.rfind("."):]
        if ext not in FILE_TYPES:
            sys.exit(f"ERROR: no known file type for {name}")
        ref_lines.append(
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {FILE_TYPES[ext]}; path = \"{name}\"; "
            f"sourceTree = \"<group>\"; }};")
        group_lines.append(f"\t\t\t\t{ref} /* {name} */,")
        build_lines.append(
            f"\t\t{bid} /* {name} in {phase_name} */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};")
        phase_lines.append(f"\t\t\t\t{bid} /* {name} in {phase_name} */,")

    src = src.replace("/* End PBXBuildFile section */",
                      "\n".join(build_lines) + "\n/* End PBXBuildFile section */", 1)
    src = src.replace("/* End PBXFileReference section */",
                      "\n".join(ref_lines) + "\n/* End PBXFileReference section */", 1)

    pat = re.compile(r"(" + APP_GROUP + r" /\* \w+ \*/ = \{.*?children = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(group_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit("ERROR: could not locate the app group's children list")

    pat = re.compile(r"(" + phase + r" /\* " + phase_name + r" \*/ = \{.*?files = \(\n)", re.S)
    src, n = pat.subn(lambda m: m.group(1) + "\n".join(phase_lines) + "\n", src, count=1)
    if n != 1:
        sys.exit(f"ERROR: could not locate the app {phase_name} build phase")

    with open(pbxproj, "w") as f:
        f.write(src)
    print("added: " + ", ".join(todo))


if __name__ == "__main__":
    main()
