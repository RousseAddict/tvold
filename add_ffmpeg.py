#!/usr/bin/env python3
"""Link the vendored FFmpeg archives into tvold.xcodeproj.

Follows the pattern curl already established in this project: headers and
libraries found via search paths, archives pulled in with -l flags, rather than
adding file references to a Frameworks build phase. Two settings that were
single strings become arrays, since there are now two ThirdParty trees.

Idempotent — safe to re-run after the project is recreated.

Run ON SERV2 from the directory holding tvold.xcodeproj.
"""

import sys

PBX = "tvold.xcodeproj/project.pbxproj"

# (old, new) — the indentation matches what Xcode writes, so a later open/save
# in the IDE produces no spurious diff.
EDITS = [
    ('HEADER_SEARCH_PATHS = "$(SRCROOT)/ThirdParty/curl/include";',
     'HEADER_SEARCH_PATHS = (\n'
     '\t\t\t\t\t"$(SRCROOT)/ThirdParty/curl/include",\n'
     '\t\t\t\t\t"$(SRCROOT)/ThirdParty/ffmpeg/include",\n'
     '\t\t\t\t);'),
    ('LIBRARY_SEARCH_PATHS = "$(SRCROOT)/ThirdParty/curl/lib";',
     'LIBRARY_SEARCH_PATHS = (\n'
     '\t\t\t\t\t"$(SRCROOT)/ThirdParty/curl/lib",\n'
     '\t\t\t\t\t"$(SRCROOT)/ThirdParty/ffmpeg/lib",\n'
     '\t\t\t\t);'),
    ('OTHER_LDFLAGS = "-lcurl -lssl -lcrypto -lz";',
     'OTHER_LDFLAGS = "-lcurl -lssl -lcrypto -lz -lavcodec -lavutil";'),
]


def main():
    text = open(PBX).read()
    if "ffmpeg/include" in text:
        print("already wired — no change")
        return
    for old, new in EDITS:
        if old not in text:
            sys.exit("ERROR: expected setting not found, project layout changed:\n  " + old)
        text = text.replace(old, new)
    open(PBX, "w").write(text)
    print("wired ffmpeg into %d build configuration(s)" % text.count("ffmpeg/include"))


if __name__ == "__main__":
    main()
