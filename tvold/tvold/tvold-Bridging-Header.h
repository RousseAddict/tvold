#include "curl_bridge.h"

// Minimal FFmpeg, AC-3 decoding only — see tools/build_ffmpeg.sh for what is
// and is not compiled into the vendored archives.
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
