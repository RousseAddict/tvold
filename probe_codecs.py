#!/usr/bin/env python3
"""Survey the catalogue's declared CODECS, to size the AC-3 problem.

Fetches each stream's master playlist and reads the CODECS attribute of its
#EXT-X-STREAM-INF variants. That attribute is the cheap answer to "would this
play on an iPhone 4S": one small HTTP request per stream, no media decoded.

It is only an answer when the stream actually serves a *master* playlist. A
stream whose URL is a media playlist (segments directly, no variants) declares
nothing, and settling those needs ffprobe on a segment — an order of magnitude
more expensive. Those are counted as `inconclusive`, not guessed at.

Classification, per Apple's iPhone 4S spec (H.264 High@L4.1 and below, AAC-LC)
and the pre-iOS-10 Core Audio limit (AC-3 is passthrough-only to an external
multichannel endpoint, so it cannot be decoded to the phone's own speaker):
    ok            every variant is H.264 + AAC
    ac3-only      has variants, none offers AAC audio  <- the M6 case
    ac3-mixed     offers both, so the player can pick AAC
    level-high    H.264 level above 4.1
    other-video   a video codec that is not H.264 (hevc, vp9, av1)

Run ON SERV2 (contained environment, good network). Output is a CSV of every
conclusive row plus a summary.

Usage: python3 probe_codecs.py <index-dir> <out.csv> [--limit N] [--workers N]
"""

import csv
import glob
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = 6
# The survey is a census of what origins advertise, not a trust boundary, and a
# broken chain on some broadcaster's CDN is exactly the kind of stream worth
# counting rather than dropping.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

STREAM_INF = re.compile(r"#EXT-X-STREAM-INF:([^\n]*)")
CODECS = re.compile(r'CODECS="([^"]*)"')
RESOLUTION = re.compile(r"RESOLUTION=(\d+)x(\d+)")


def load(index_dir):
    out = []
    for path in sorted(glob.glob(os.path.join(index_dir, "*.json"))):
        cc = os.path.basename(path)[:-5]
        if cc == "countries":
            continue
        for e in json.load(open(path)):
            out.append({"cc": cc, "name": e.get("n", ""), "url": e.get("u", ""),
                        "ua": e.get("ua"), "rf": e.get("rf")})
    return out


def fetch(entry):
    req = urllib.request.Request(entry["url"])
    # The 1,025 streams that 403 without them are the same ones the proxy has
    # to inject for, so the survey has to send them too or it undercounts.
    req.add_header("User-Agent", entry["ua"] or "tvold/1.0 (iOS 6 IPTV client)")
    if entry["rf"]:
        req.add_header("Referer", entry["rf"])
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as r:
        return r.read(262144).decode("utf-8", "replace")


def classify(variants):
    """variants: list of (codecs_string, height). Returns a verdict string."""
    if not variants:
        return "inconclusive"
    has_aac = False
    has_ac3 = False
    non_h264 = False
    level_high = False
    for codecs, _h in variants:
        parts = [c.strip().lower() for c in codecs.split(",") if c.strip()]
        for p in parts:
            if p.startswith("mp4a"):
                has_aac = True
            elif p in ("ac-3", "ec-3") or p.startswith("ac-3") or p.startswith("ec-3"):
                has_ac3 = True
            elif p.startswith("avc1"):
                # avc1.PPCCLL — last byte is level x10 in hex. 4.1 -> 0x29.
                tail = p.split(".")[-1]
                if len(tail) >= 6:
                    try:
                        if int(tail[4:6], 16) > 0x29:
                            level_high = True
                    except ValueError:
                        pass
            elif p.startswith(("hvc1", "hev1", "vp09", "vp9", "av01")):
                non_h264 = True
    if non_h264:
        return "other-video"
    if has_ac3 and not has_aac:
        return "ac3-only"
    if has_ac3 and has_aac:
        return "ac3-mixed"
    if level_high:
        return "level-high"
    return "ok"


def probe(entry):
    try:
        body = fetch(entry)
    except Exception as exc:  # noqa: BLE001 - any failure is just "unreachable"
        return {**entry, "verdict": "unreachable", "detail": type(exc).__name__,
                "codecs": "", "height": ""}
    variants = []
    for attrs in STREAM_INF.findall(body):
        c = CODECS.search(attrs)
        r = RESOLUTION.search(attrs)
        variants.append((c.group(1) if c else "", int(r.group(2)) if r else 0))
    verdict = classify(variants)
    if verdict == "inconclusive":
        # Distinguish "served us a media playlist" from "served us junk" — the
        # first is a stream we simply cannot judge this cheaply, the second is
        # very likely not a playlist at all.
        detail = "media-playlist" if "#EXTINF" in body else "not-a-playlist"
        return {**entry, "verdict": verdict, "detail": detail, "codecs": "", "height": ""}
    return {**entry, "verdict": verdict, "detail": f"{len(variants)} variant(s)",
            "codecs": " | ".join(v[0] for v in variants),
            "height": max((v[1] for v in variants), default=0)}


def main():
    args = sys.argv[1:]
    workers = 40
    limit = None
    for flag, cast in (("--workers", int), ("--limit", int)):
        if flag in args:
            i = args.index(flag)
            value = cast(args[i + 1])
            del args[i:i + 2]
            if flag == "--workers":
                workers = value
            else:
                limit = value
    if len(args) != 2:
        sys.exit(__doc__)
    index_dir, out_path = args

    entries = load(index_dir)
    if limit:
        entries = entries[:limit]
    print(f"probing {len(entries)} streams with {workers} workers", flush=True)

    counts = Counter()
    done = 0
    with open(out_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["cc", "name", "url", "ua", "rf",
                                           "verdict", "detail", "codecs", "height"])
        w.writeheader()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for row in pool.map(probe, entries):
                counts[row["verdict"]] += 1
                w.writerow(row)
                done += 1
                if done % 500 == 0:
                    print(f"  {done}/{len(entries)}  {dict(counts)}", flush=True)

    print("\n=== verdicts ===")
    for verdict, n in counts.most_common():
        print(f"  {verdict:<14} {n:>6}  {100.0 * n / len(entries):5.1f}%")
    conclusive = sum(n for v, n in counts.items()
                     if v not in ("unreachable", "inconclusive"))
    print(f"\nconclusive: {conclusive} of {len(entries)}")
    if conclusive:
        ac3 = counts["ac3-only"]
        print(f"ac3-only is {ac3} = {100.0 * ac3 / conclusive:.1f}% of conclusive")


if __name__ == "__main__":
    main()
