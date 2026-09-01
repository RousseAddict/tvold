#!/bin/bash
# Cross-compile a minimal FFmpeg (AC-3 decode only) for iOS, armv7 + arm64.
#
# Scope is deliberately tiny: --disable-everything, then only the AC-3 family
# back on. tvold needs exactly one thing FFmpeg has and CoreAudio does not — an
# AC-3 decoder that produces PCM on the phone's own speaker. Everything else it
# can do is attack surface and bytes in the IPA.
#
# libavcodec + libavutil only. No avformat: the TS demuxing is ours, and pulling
# in avformat would drag protocols and network code we have no use for.
#
# Run ON SERV2:  ./build_ffmpeg.sh
# Output:        vendor/ffmpeg-ios/{include,lib}/  (lib*.a are fat armv7+arm64)

set -e

VERSION=6.1.6
VENDOR=~/Documents/ios6-app/tvold/vendor
SRC="$VENDOR/ffmpeg-$VERSION"
OUT="$VENDOR/ffmpeg-ios"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)

[ -d "$SRC" ] || { echo "ERROR: $SRC not found — unpack the tarball first"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# armv7 can target 6.0; arm64 did not exist before iOS 7, so 7.0 is its floor.
# This only affects the objects' build attributes — a static archive carries no
# LC_VERSION_MIN, and the app binary that links it is patched to 6.0 by build.sh.
build_arch() {
  local arch="$1" minver="$2" cpu="$3"
  echo "==> building $arch (min iOS $minver)"

  local build="$VENDOR/build-$arch"
  rm -rf "$build" && mkdir -p "$build"
  cd "$build"

  local flags="-arch $arch -miphoneos-version-min=$minver -isysroot $SDK -fno-stack-protector"

  "$SRC/configure" \
    --prefix="$VENDOR/out-$arch" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="$arch" \
    --cpu="$cpu" \
    --cc="$CC" \
    --as="$CC" \
    --sysroot="$SDK" \
    --extra-cflags="$flags" \
    --extra-ldflags="$flags" \
    --enable-static \
    --disable-shared \
    --enable-pic \
    --disable-everything \
    --disable-autodetect \
    --disable-programs \
    --disable-doc \
    --disable-avdevice \
    --disable-avformat \
    --disable-avfilter \
    --disable-swscale \
    --disable-swresample \
    --disable-postproc \
    --disable-network \
    --disable-protocols \
    --disable-devices \
    --disable-debug \
    --enable-decoder=ac3 \
    --enable-decoder=ac3_fixed \
    --enable-decoder=eac3 \
    --enable-parser=ac3 \
    > configure.log 2>&1 || { echo "configure FAILED — tail:"; tail -30 configure.log; exit 1; }

  make -j"$(sysctl -n hw.ncpu)" > build.log 2>&1 \
    || { echo "make FAILED — tail:"; tail -30 build.log; exit 1; }
  make install > install.log 2>&1

  echo "    ok: $(ls -lh "$VENDOR/out-$arch/lib"/*.a | awk '{print $9" "$5}' | tr '\n' ' ')"
}

build_arch armv7 6.0 cortex-a8
build_arch arm64 7.0 generic

# One fat archive per library so the Xcode target links a single file per arch.
mkdir -p "$OUT/lib" "$OUT/include"
for lib in libavcodec libavutil; do
  lipo -create "$VENDOR/out-armv7/lib/$lib.a" "$VENDOR/out-arm64/lib/$lib.a" \
       -output "$OUT/lib/$lib.a"
done
cp -R "$VENDOR/out-arm64/include/"* "$OUT/include/"

echo
echo "=== result ==="
for f in "$OUT/lib"/*.a; do
  echo "$(basename "$f")  $(ls -lh "$f" | awk '{print $5}')  [$(lipo -archs "$f")]"
done
du -sh "$OUT"
