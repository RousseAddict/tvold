import Foundation

// AC-3 -> interleaved signed-16 PCM, using the vendored minimal FFmpeg.
//
// This exists because Core Audio's AC-3 support before iOS 10 is passthrough
// only: it can hand a bitstream to an HDMI or AirPlay receiver, but it cannot
// decode one to the phone's own speaker. So the ten AC-3-only channels in the
// catalogue are silent on a 4S no matter what the proxy does, and decoding has
// to happen in the app.
//
// Output is deliberately the exact shape AACEncoder.encode wants — interleaved
// Int16 — so nothing sits between the two.
final class AC3Decoder {

    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    private(set) var sampleRate = 0
    private(set) var channels = 0

    // FFmpeg's AV_NOPTS_VALUE is a cast macro, so Swift's C importer drops it.
    // The value is 0x8000000000000000 as a signed 64-bit integer.
    private static let noPTS = Int64.min

    // `ac3_fixed`, FFmpeg's integer decoder, rather than the float `ac3`: it
    // outputs planar Int16, so feeding the encoder is an interleave instead of a
    // clamp and a scale per sample. Both were compiled in and compared on device
    // at `-O`; the speed difference is within noise, so this is chosen for the
    // cheaper output format alone.
    init?() {
        let name = "ac3_fixed"
        guard let codec = avcodec_find_decoder_by_name(name) else {
            DebugLog.shared.log("AC3", "decoder '\(name)' not in this build")
            return nil
        }
        guard let context = avcodec_alloc_context3(codec) else { return nil }
        ctx = context
        guard avcodec_open2(context, codec, nil) == 0 else {
            DebugLog.shared.log("AC3", "avcodec_open2 failed for '\(name)'")
            return nil
        }
        // The parser splits a byte stream into whole AC-3 frames. PES payloads
        // usually start on a syncword, but "usually" is not something to build
        // a decoder loop on.
        parser = av_parser_init(Int32(codec.pointee.id.rawValue))
        pkt = av_packet_alloc()
        frame = av_frame_alloc()
        guard parser != nil, pkt != nil, frame != nil else { return nil }
    }

    deinit {
        if frame != nil { av_frame_free(&frame) }
        if pkt != nil { av_packet_free(&pkt) }
        if let p = parser { av_parser_close(p) }
        if ctx != nil { avcodec_free_context(&ctx) }
    }

    // MARK: - Decoding

    // Feeds a raw AC-3 byte stream and returns interleaved Int16 PCM. Safe to
    // call repeatedly; decoder state carries across calls, which is what makes
    // it usable segment by segment on a live stream.
    func decode(_ input: [UInt8]) -> [Int16] {
        guard let ctx = ctx, let parser = parser, let pkt = pkt, let frame = frame,
              !input.isEmpty else { return [] }

        var out: [Int16] = []
        var buffer = input

        buffer.withUnsafeMutableBufferPointer { raw in
            var offset = 0
            var stalls = 0
            while offset < raw.count {
                var outBuf: UnsafeMutablePointer<UInt8>?
                var outSize: Int32 = 0
                let consumed = av_parser_parse2(
                    parser, ctx, &outBuf, &outSize,
                    raw.baseAddress! + offset, Int32(raw.count - offset),
                    AC3Decoder.noPTS, AC3Decoder.noPTS, 0)

                // Consuming nothing while emitting a frame is NORMAL: the parser
                // had a frame buffered whose end fell on the previous buffer's
                // boundary, and the following call makes progress. So it is the
                // *pair* stalling that ends the loop, not the cursor alone.
                //
                // Breaking on `consumed <= 0` by itself abandoned the rest of
                // every segment, which starved the encoder and made M6
                // reconnect until it gave up (2026-09-05). Do not "simplify"
                // this back.
                //
                // The two things worth guarding are a negative count, which
                // would walk the cursor back out of the buffer, and a genuine
                // run of no-progress calls.
                if consumed > 0 {
                    stalls = 0
                    offset += Int(consumed)
                } else {
                    stalls += 1
                    if outSize <= 0 || stalls > 8 { break }
                }

                guard outSize > 0, let framed = outBuf else { continue }
                pkt.pointee.data = framed
                pkt.pointee.size = outSize
                if avcodec_send_packet(ctx, pkt) != 0 { continue }
                while avcodec_receive_frame(ctx, frame) == 0 {
                    append(frame, to: &out)
                }
            }
        }
        return out
    }

    // Planar in, interleaved out. AC-3 decoders emit one plane per channel;
    // the AAC encoder wants the channels woven together.
    private func append(_ frame: UnsafeMutablePointer<AVFrame>, to out: inout [Int16]) {
        let samples = Int(frame.pointee.nb_samples)
        let nch = Int(frame.pointee.ch_layout.nb_channels)
        guard samples > 0, nch > 0, let planes = frame.pointee.extended_data else { return }

        sampleRate = Int(frame.pointee.sample_rate)
        channels = nch

        // `ac3_fixed` produces planar Int16 and nothing else — any other format
        // means the vendored FFmpeg build changed underneath us.
        switch frame.pointee.format {
        case AV_SAMPLE_FMT_S16P.rawValue:
            for s in 0..<samples {
                for c in 0..<nch {
                    guard let plane = planes[c] else { continue }
                    let v = plane.withMemoryRebound(to: Int16.self, capacity: samples) {
                        $0[s]
                    }
                    out.append(v)
                }
            }
        default:
            DebugLog.shared.log("AC3", "unexpected sample format \(frame.pointee.format)")
        }
    }
}
