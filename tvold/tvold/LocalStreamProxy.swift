import Foundation
import Darwin

// Local HTTP server that fronts playback (HLS video and direct audio streams
// alike) so MPMoviePlayerController/AVPlayer never talk TLS directly.
//
// It binds INADDR_ANY rather than loopback. AirPlay video is a *URL handoff* —
// the receiver fetches the stream itself — so an Apple TV has to be able to
// reach this server, and it cannot reach the phone's 127.0.0.1. Every path is
// therefore namespaced under a per-session random token, so what is exposed on
// the LAN for the life of a channel is not guessable.
//
// Neither player backend can be pointed at libcurl: MPMoviePlayerController
// has no networking delegate hook at all, and AVPlayer's resource-loader
// delegate only intercepts custom URL schemes, not plain http(s). Routing
// playback through a local plain-HTTP server sidesteps both — the player
// only ever talks unencrypted HTTP to this device, while every real fetch to
// the Jellyfin server goes through libcurl + embedded OpenSSL, which — unlike
// iOS 6/7 Secure Transport — negotiates GCM-only TLS cipher suites correctly.
//
// Segments and direct audio streams are relayed as bytes arrive from curl's
// write callback straight to the client socket (true streaming — nothing
// buffered to RAM/disk; the blocking send() gives natural backpressure).
// Master/variant playlists are the one exception: they're small text and
// need to be fully parsed to rewrite URIs, so those are fetched whole via
// CurlFetcher, rewritten, then sent.
//
// Each accepted connection runs on its own raw NSThread (not a GCD queue) —
// a connection blocks synchronously inside curl_easy_perform for the whole
// transfer, which can be many seconds for a video segment; a limited-width
// concurrent GCD queue would stall once the player opens several connections
// at once.
final class LocalStreamProxy: NSObject {
    private var listenSocket: Int32 = -1
    private var port: UInt16 = 0
    private var started = false

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    // Reverse of `routes`, so a remote URL always maps to the same local path.
    private var pathByURL: [String: String] = [:]
    private var nextID = 0
    private var currentGen: UInt64 = 0

    // Every path of a session lives under /<token>/. The server is reachable
    // from the whole subnet, so a bare /1.ts would be trivially guessable by
    // anything else on the wifi; the token is minted per start() and dies with
    // the routes it namespaces.
    private var sessionToken = LocalStreamProxy.randomToken()

    // Variants taller than this are stripped from master playlists. An A5/A6
    // decoder tops out well below what a modern IPTV origin advertises, and
    // MPMoviePlayerController picks the top rung by default — which shows up
    // as a black picture that looks exactly like a proxy failure but isn't.
    var maxVariantHeight = 720

    // Segments kept from the live edge of a media playlist.
    //
    // Broadcaster packagers publish enormous DVR windows: Das Erste lists 3,600
    // segments (464 KB) and asks to be reloaded every 2 s, hr-fernsehen and WDR
    // the same, Asharq Discovery 14,399. iOS 6 itself parses those fine — tested
    // in MobileSafari straight off the origin — but rewriting every URI to a
    // local path costs ~21 ms per line on an A5, i.e. ~77 s for Das Erste, so
    // the playlist was never served and the player timed out at 15 s.
    //
    // Nobody scrubs back two hours on this device. Keeping the last 30 leaves a
    // minute of window at a 2 s target duration, far above the three target
    // durations RFC 8216 requires.
    var maxLiveSegments = 30

    // The segment `serveSegment` produced last, kept so a repeat request does
    // not refetch and re-transcode it.
    //
    // One entry, because every duplicate observed on device was for the segment
    // just served: a receiver that ran short re-asks immediately, either whole
    // or by byte range. It also fixes a corruption bug — a ranged request used
    // to fall through to the relay and be answered with a slice of the *source*
    // AC-3 file, whose offsets do not match the transcoded output at all, so
    // the client stitched AAC to AC-3 and the stream died a second later.
    //
    // Only the buffered path can do this. A relayed segment is never held whole
    // by design and caching one would mean holding several MB per connection.
    private var lastSegmentPath: String?
    private var lastSegmentBody: Data?

    // AC-3 -> AAC conversion for the stream currently playing. Replaced rather
    // than reset on each start(): the decoder and encoder inside it carry state
    // across segments, and none of that state means anything for a new channel.
    private var transcoder = SegmentTranscoder()

    // A registered route: where to fetch, plus the headers that fetch needs.
    // Some IPTV origins 403 without a specific User-Agent or Referer, and the
    // requirement is per-stream — so the headers travel with the URL rather
    // than being a property of the proxy.
    //
    // `isSegment` is true only for routes discovered inside a playlist, which
    // is what makes it safe to buffer them whole for transcoding: an HLS
    // segment is a few seconds and a few MB, whereas the URL the caller hands
    // to start() may well be an endless MPEG-TS that must never be buffered.
    struct Route {
        let url: URL
        let headers: [String: String]
        let isSegment: Bool
    }

    // Starts the server (if not already running) and registers `remoteURL`
    // as a route. Returns the local URL to hand to the player, or nil if the
    // loopback socket couldn't be created — the caller should fall back to
    // the direct remote URL in that case. Bumps the generation counter so
    // any connections still serving a previous stream get cancelled.
    //
    // `extHint` supplies the extension to advertise when the remote URL has
    // none of its own. The default for that case is "ts", which is right for
    // HLS segments but an actively wrong type hint for anything else — e.g.
    // Jellyfin's audio endpoint (/Audio/{id}/universal) has no extension, and
    // serving an mp3 from /1.ts stops the player dead.
    //
    // `headers` are sent on every upstream fetch for this stream, including
    // the playlists and segments discovered underneath it.
    func start(remoteURL: URL, extHint: String? = nil, headers: [String: String] = [:]) -> URL? {
        lock.lock()
        currentGen += 1
        let gen = currentGen
        // The previous stream's routes die with its generation, and the memo
        // table must not carry a path across from the channel just zapped away.
        routes.removeAll()
        pathByURL.removeAll()
        lastSegmentPath = nil
        lastSegmentBody = nil
        sessionToken = LocalStreamProxy.randomToken()
        transcoder = SegmentTranscoder()
        lock.unlock()
        guard ensureStarted() else {
            DebugLog.shared.log("Proxy", "start FAILED (socket unavailable) — caller will use the direct URL, TLS unprotected")
            return nil
        }
        let path = registerPath(for: remoteURL, isPlaylist: LocalStreamProxy.isPlaylistURL(remoteURL),
                                gen: gen, extHint: extHint, headers: headers)
        // The host in the URL handed to the player is what an AirPlay receiver
        // will later be told to fetch, so it has to be the phone's LAN address
        // rather than 127.0.0.1. Local playback is unaffected — the phone
        // reaches its own wifi address as happily as it reaches loopback.
        let host = LocalStreamProxy.lanAddress()
        DebugLog.shared.log("Proxy", "start gen=\(gen) host=\(host.value)"
            + " (\(host.how)) \(path) -> \(DebugLog.redact(remoteURL.absoluteString))")
        return URL(string: "http://\(host.value):\(port)\(path)")
    }

    // MARK: - Addressing

    // The phone's IPv4 address on the local network, or loopback when there is
    // no usable interface (cellular-only, airplane mode). `how` is carried for
    // the log: which interface was picked is the first thing to check when an
    // AirPlay receiver cannot reach us.
    static func lanAddress() -> (value: String, how: String) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return ("127.0.0.1", "getifaddrs failed")
        }
        defer { freeifaddrs(head) }

        var best: String?
        var bestName = ""
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr else { continue }
            guard Int32(sa.pointee.sa_family) == AF_INET else { continue }
            let flags = ifa.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0 else { continue }
            guard flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // pdp_ip* is cellular: routable to the internet but not to anything
            // on the same room's network, which is the only thing that matters.
            if name.hasPrefix("pdp_ip") { continue }
            let text = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                dottedQuad($0.pointee.sin_addr.s_addr)
            }
            // en0 is wifi and is what an Apple TV shares a subnet with. Anything
            // else (en1, bridge100 for personal hotspot) is a fallback only.
            if name == "en0" { return (text, "en0") }
            if best == nil { best = text; bestName = name }
        }
        if let b = best { return (b, bestName) }
        return ("127.0.0.1", "no non-loopback IPv4 interface")
    }

    // s_addr is in network byte order, so the first octet is the low byte.
    // Written out one octet at a time: the combined shift-and-mask expression
    // sends the 5.6.3 type checker into a stall on this target.
    private static func dottedQuad(_ s_addr: in_addr_t) -> String {
        let raw = UInt32(s_addr)
        let a: UInt32 = raw & 0xFF
        let b: UInt32 = (raw >> 8) & 0xFF
        let c: UInt32 = (raw >> 16) & 0xFF
        let d: UInt32 = (raw >> 24) & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    // Hand-rolled rather than String(format:) — a varargs bridge binds lazily
    // against the shipped 5.1.5 overlay and takes the process down at first use.
    private static func randomToken() -> String {
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                "8", "9", "a", "b", "c", "d", "e", "f"]
        var out = [Character]()
        out.reserveCapacity(12)
        for _ in 0..<12 { out.append(hex[Int(arc4random_uniform(16))]) }
        return String(out)
    }

    // Who is on the other end of an accepted connection. Read from the socket
    // rather than threaded through, so nothing else has to change to get it.
    private static func peerName(_ fd: Int32) -> String {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }
        guard ok == 0 else { return "?" }
        return dottedQuad(addr.sin_addr.s_addr)
    }

    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        DebugLog.shared.log("Proxy", "stop (gen \(currentGen) -> \(currentGen + 1)), \(routes.count) route(s) dropped")
        started = false
        currentGen += 1
        let fd = listenSocket
        listenSocket = -1
        routes.removeAll()
        lastSegmentPath = nil
        lastSegmentBody = nil
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    fileprivate func isSuperseded(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen < currentGen
    }

    // MARK: - Socket setup

    private func ensureStarted() -> Bool {
        lock.lock()
        if started { lock.unlock(); return true }
        lock.unlock()

        CurlFetcher.ensureGlobalInit()
        signal(SIGPIPE, SIG_IGN) // a send() to a socket the player already closed must not kill the process

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        // INADDR_ANY, not loopback: an AirPlay receiver fetches the stream
        // itself and cannot reach the phone's 127.0.0.1.
        addr.sin_addr.s_addr = in_addr_t(0)
        addr.sin_port = 0 // let the OS assign an ephemeral port

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            DebugLog.shared.log("Proxy", "failed to bind/listen (errno \(errno))")
            close(fd)
            return false
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        lock.lock()
        listenSocket = fd
        port = UInt16(bigEndian: boundAddr.sin_port)
        started = true
        lock.unlock()

        let lan = LocalStreamProxy.lanAddress()
        DebugLog.shared.log("Proxy", "listening on 0.0.0.0:\(port)"
            + " — LAN address is \(lan.value) via \(lan.how)")

        let accept = Thread(target: self, selector: #selector(acceptLoopEntry(_:)), object: NSNumber(value: fd))
        accept.stackSize = 256 * 1024
        accept.start()
        return true
    }

    @objc private func acceptLoopEntry(_ arg: Any) {
        guard let fd = (arg as? NSNumber)?.int32Value else { return }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread(target: self, selector: #selector(handleConnectionEntry(_:)), object: NSNumber(value: client))
            t.stackSize = 256 * 1024
            t.start()
        }
    }

    @objc private func handleConnectionEntry(_ arg: Any) {
        guard let fd = (arg as? NSNumber)?.int32Value else { return }
        handle(connection: fd)
    }

    // MARK: - Path <-> remote URL mapping

    private func registerPath(for remoteURL: URL, isPlaylist: Bool, gen: UInt64,
                              extHint: String? = nil, headers: [String: String],
                              isSegment: Bool = false) -> String {
        lock.lock(); defer { lock.unlock() }
        // One path per remote URL, stable for the life of the stream.
        //
        // A live playlist is reloaded every few seconds and re-lists the
        // segments still inside its sliding window. Minting a fresh path each
        // time handed the player a brand-new URI for a segment it had already
        // played, and since a player identifies segments by URI, it fetched and
        // played that segment a second time. It also grew `routes` without
        // bound for the length of the session.
        let key = remoteURL.absoluteString
        if let existing = pathByURL[key] { return existing }

        nextID += 1
        let urlExt = LocalStreamProxy.fileExtension(of: remoteURL)
        let ext = isPlaylist ? "m3u8" : (urlExt.isEmpty ? (extHint ?? "ts") : urlExt)
        let path = "/\(sessionToken)/\(nextID).\(ext)"
        routes[path] = Route(url: remoteURL, headers: headers, isSegment: isSegment)
        pathByURL[key] = path
        return path
    }

    static func isPlaylistURL(_ url: URL) -> Bool {
        return fileExtension(of: url) == "m3u8"
    }

    static func fileExtension(of url: URL) -> String {
        // Fast path: NSURL computes this in C. It must stay the common case —
        // this runs once per line of a playlist that can hold 1000+ segments,
        // and the fallback below is orders of magnitude more expensive
        // (absoluteString hands back a bridged NSString, and walking one of
        // those from Swift is brutally slow on an A4/A5).
        let ext = url.pathExtension
        if !ext.isEmpty { return ext.lowercased() }
        // Empty means either genuinely no extension, or a non-hierarchical
        // URL — which is what a server address stored without a scheme
        // produces ("host:8096/..." parses as scheme "host", leaving path and
        // pathExtension empty). Slice the raw string with NSString's C path
        // helpers rather than Swift character indexing.
        var s = url.absoluteString as NSString
        let hash = s.range(of: "#")
        if hash.location != NSNotFound { s = s.substring(to: hash.location) as NSString }
        let q = s.range(of: "?")
        if q.location != NSNotFound { s = s.substring(to: q.location) as NSString }
        return s.pathExtension.lowercased()
    }

    private func route(for path: String) -> Route? {
        lock.lock(); defer { lock.unlock() }
        return routes[path]
    }

    private var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentGen
    }

    // MARK: - Connection handling

    private func handle(connection fd: Int32) {
        defer { close(fd) }
        let gen = generation
        let peer = LocalStreamProxy.peerName(fd)
        // A remote peer is, on this app, an AirPlay receiver pulling the stream
        // — the one fact the whole handoff turns on, so it is called out rather
        // than left to be inferred from an address.
        let who = peer == "127.0.0.1" ? "local" : "REMOTE \(peer)"
        guard let head = readRequestHead(fd),
              let (method, path, rangeHeader, agent) = parseRequest(head) else {
            DebugLog.shared.log("Proxy", "REQ from \(who): unparseable request head — answering 400")
            sendStatusOnly(fd, "400 Bad Request")
            return
        }
        let ua = agent.isEmpty ? "" : " ua=\(agent)"
        guard let rt = route(for: path) else {
            DebugLog.shared.log("Proxy", "REQ \(method) \(path) from \(who)\(ua)"
                + " -> 404 (no such route; \(routeCount) registered)")
            sendStatusOnly(fd, "404 Not Found")
            return
        }
        DebugLog.shared.log("Proxy", "REQ \(method) \(path) from \(who)\(ua)"
            + "\(rangeHeader.map { " [\($0)]" } ?? "") -> \(DebugLog.redact(rt.url.absoluteString))")
        // AppleCoreMedia probes with HEAD before it commits to a transfer.
        // Answering it with a body would leave a whole segment on the wire that
        // the receiver discards; answering the status alone is what HEAD means.
        if method == "HEAD" {
            let type = path.hasSuffix(".m3u8")
                ? "application/vnd.apple.mpegurl" : "video/mp2t"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n"
                + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            _ = LocalStreamProxy.sendAll(fd, Array(resp.utf8))
            return
        }
        // A repeat of the segment just transcoded — including the byte-range
        // retry a receiver makes when the first delivery came up short.
        if !path.hasSuffix(".m3u8"), let body = cachedSegment(for: path) {
            sendCachedSegment(body, rangeHeader: rangeHeader, path: path, clientFd: fd)
            return
        }
        let convertible = rt.isSegment && rangeHeader == nil
        if path.hasSuffix(".m3u8") {
            servePlaylist(route: rt, gen: gen, path: path, clientFd: fd)
        } else if convertible && currentTranscoder.verdict == .transcode {
            // Buffered, because a transcode cannot emit its first byte until it
            // has seen the last one. Only for a stream already known to be
            // AC-3: buffering to *find out* costs the whole first-segment fetch
            // before the player sees a byte, which on a slow origin is 7-10s
            // and reads to the player as a dead stream. A ranged request is
            // left alone regardless — half a segment has no PMT to read and no
            // whole AC-3 frame to convert.
            serveSegment(route: rt, gen: gen, path: path, clientFd: fd)
        } else {
            // An undecided stream relays normally and is judged from a prefix
            // taken in passing, so the common case (already AAC) costs nothing.
            streamRemote(rt, gen: gen, path: path, rangeHeader: rangeHeader,
                         sniff: convertible && currentTranscoder.verdict == .unknown,
                         clientFd: fd)
        }
    }

    private var routeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return routes.count
    }

    // start() swaps the transcoder out on whichever thread the player was
    // zapped from, while connection threads are reading it.
    private var currentTranscoder: SegmentTranscoder {
        lock.lock(); defer { lock.unlock() }
        return transcoder
    }

    // fileprivate so the C body callback, which is not an extension of this
    // class, can reach it.
    fileprivate func inspectSniff(_ prefix: Data) {
        currentTranscoder.inspect(prefix)
    }

    // Reads until the blank line that ends an HTTP request head. Bounded so a
    // misbehaving client can't make this spin forever. No request body is
    // ever expected (GET only), so nothing past the head needs reading.
    private func readRequestHead(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        let terminator = Data("\r\n\r\n".utf8)
        while data.range(of: terminator) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .isoLatin1) }
            data.append(buf, count: n)
            if data.count > 16 * 1024 { break }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private func parseRequest(_ head: String)
            -> (method: String, path: String, rangeHeader: String?, agent: String)? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        var rangeHeader: String?
        var agent = ""
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") { rangeHeader = line }
            // An Apple TV identifies itself here (AppleCoreMedia/… AppleTV…),
            // which is how the log tells its fetches apart from the phone's.
            if lower.hasPrefix("user-agent:") {
                agent = String(line.dropFirst("user-agent:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return (method, path, rangeHeader, agent)
    }

    private func sendStatusOnly(_ fd: Int32, _ status: String) {
        let head = "HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n"
        LocalStreamProxy.sendAll(fd, Array(head.utf8))
    }

    // MARK: - Playlists (buffered — small text, needs full parsing to rewrite URIs)

    private func servePlaylist(route: Route, gen: UInt64, path: String, clientFd: Int32) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let data = CurlFetcher.fetchSyncData(url: route.url.absoluteString,
                                                   headers: route.headers) else {
            // fetchSyncData returns nil for a transport error OR a non-2xx
            // status — a TLS handshake failure lands here.
            DebugLog.shared.log("Proxy", "PLAYLIST \(path) FETCH FAILED after \(ms(since: t0))ms (transport error or non-2xx) \(DebugLog.redact(route.url.absoluteString))")
            sendStatusOnly(clientFd, "502 Bad Gateway")
            return
        }
        DebugLog.shared.log("Proxy", "PLAYLIST \(path) fetched \(data.count)B in \(ms(since: t0))ms")
        let trimmed = trimLiveWindow(data, path: path)
        let body = rewritePlaylist(trimmed, route: route, gen: gen, path: path)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard LocalStreamProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = LocalStreamProxy.sendAll(clientFd, base.assumingMemoryBound(to: UInt8.self), body.count)
            }
        }
    }

    private func ms(since t0: CFAbsoluteTime) -> Int {
        return Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    // MARK: - Segments that may need transcoding (buffered)

    // Fetches a segment whole, offers it to the transcoder, and sends the
    // result with a real Content-Length. This is the slow path: it holds a few
    // MB and cannot start sending until the fetch completes, so it is used only
    // while the stream's audio codec is still in question or known to need
    // converting.
    private func cachedSegment(for path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return lastSegmentPath == path ? lastSegmentBody : nil
    }

    private func cacheSegment(_ body: Data, for path: String) {
        guard !body.isEmpty else { return }
        lock.lock()
        lastSegmentPath = path
        lastSegmentBody = body
        lock.unlock()
    }

    // Serves a segment already in hand, honouring a Range if one was asked for.
    // The offsets here are offsets into the *transcoded* bytes, which is the
    // whole point: they are the only ones the client's own byte count agrees
    // with.
    private func sendCachedSegment(_ body: Data, rangeHeader: String?, path: String,
                                   clientFd: Int32) {
        var start = 0
        var end = body.count - 1
        var partial = false
        if let h = rangeHeader {
            guard let r = LocalStreamProxy.parseByteRange(h, count: body.count) else {
                DebugLog.shared.log("Proxy", "CACHED \(path) unsatisfiable range \(h)")
                sendStatusOnly(clientFd, "416 Requested Range Not Satisfiable")
                return
            }
            start = r.start
            end = r.end
            partial = true
        }
        let length = end - start + 1
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: video/MP2T\r\nAccept-Ranges: bytes\r\n"
        if partial {
            head += "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
        }
        head += "Content-Length: \(length)\r\nConnection: close\r\n\r\n"
        guard LocalStreamProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = LocalStreamProxy.sendAll(clientFd,
                                             base.assumingMemoryBound(to: UInt8.self) + start,
                                             length)
            }
        }
        DebugLog.shared.log("Proxy", "CACHED \(path) served \(length)B"
            + (partial ? " [\(start)-\(end)/\(body.count)]" : " (whole)")
            + " — no refetch, no re-transcode")
    }

    // "Range: bytes=START-END", "bytes=START-" and the suffix form "bytes=-N".
    // Returns nil when the range cannot be satisfied against `count`.
    private static func parseByteRange(_ header: String, count: Int) -> (start: Int, end: Int)? {
        guard count > 0, let eq = header.range(of: "bytes=") else { return nil }
        let spec = String(header[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Multi-range is legal HTTP and never sent by a media client; refusing
        // it is safer than answering only the first part of what was asked.
        guard spec.range(of: ",") == nil else { return nil }
        let parts = spec.components(separatedBy: "-")
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let n = Int(parts[1]), n > 0 else { return nil }
            return (max(0, count - n), count - 1)
        }
        guard let s = Int(parts[0]), s >= 0, s < count else { return nil }
        guard !parts[1].isEmpty else { return (s, count - 1) }
        guard let e = Int(parts[1]), e >= s else { return nil }
        return (s, min(e, count - 1))
    }

    private func serveSegment(route: Route, gen: UInt64, path: String, clientFd: Int32) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let data = CurlFetcher.fetchSyncData(url: route.url.absoluteString,
                                                   headers: route.headers, timeout: 30) else {
            DebugLog.shared.log("Proxy", "SEGMENT \(path) FETCH FAILED after \(ms(since: t0))ms \(DebugLog.redact(route.url.absoluteString))")
            sendStatusOnly(clientFd, "502 Bad Gateway")
            return
        }
        // The channel may have been zapped away while this was in flight, in
        // which case the player on the other end is gone too.
        if isSuperseded(gen) {
            DebugLog.shared.log("Proxy", "SEGMENT \(path) superseded after fetch — dropped")
            return
        }
        let body = currentTranscoder.process(data)
        // Cached before sending, so a client that gives up mid-transfer and
        // retries is answered from memory even though this send never finished.
        cacheSegment(body, for: path)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: video/MP2T\r\nAccept-Ranges: bytes\r\n"
                 + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard LocalStreamProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = LocalStreamProxy.sendAll(clientFd, base.assumingMemoryBound(to: UInt8.self),
                                             body.count)
            }
        }
        DebugLog.shared.log("Proxy", "SEGMENT \(path) ok \(data.count)B in / \(body.count)B out "
                            + "in \(ms(since: t0))ms")
    }

    // Cuts a live media playlist down to its last `maxLiveSegments` segments
    // before anything else touches it.
    //
    // This runs on the raw bytes on purpose. The cost being avoided is not just
    // the per-line rewrite — decoding 464 KB into a String and splitting it into
    // 10,804 of them is ~450 ms on an A5 before a single URI has been resolved.
    // Scanning for newlines and slicing the tail costs neither.
    //
    // Returns `data` unchanged whenever trimming would be wrong or pointless:
    // masters, finished/VOD playlists, anything short enough already, and
    // encrypted or fMP4 playlists whose #EXT-X-KEY / #EXT-X-MAP tag applies
    // forward from inside the region that would be discarded.
    private func trimLiveWindow(_ data: Data, path: String) -> Data {
        let t0 = CFAbsoluteTimeGetCurrent()

        let bEXTINF     = Array("#EXTINF".utf8)
        let bSTREAMINF  = Array("#EXT-X-STREAM-INF".utf8)
        let bENDLIST    = Array("#EXT-X-ENDLIST".utf8)
        let bVOD        = Array("#EXT-X-PLAYLIST-TYPE:VOD".utf8)
        let bKEY        = Array("#EXT-X-KEY".utf8)
        let bMAP        = Array("#EXT-X-MAP".utf8)
        let bDISC       = Array("#EXT-X-DISCONTINUITY".utf8)

        var segGroupStart: [Int] = []
        var discontinuityAt: [Int] = []
        var headerEnd = -1
        var groupStart = 0
        var bail = false

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                bail = true; return
            }
            let n = raw.count
            func matches(_ off: Int, _ pat: [UInt8]) -> Bool {
                guard off + pat.count <= n else { return false }
                for k in 0..<pat.count where base[off + k] != pat[k] { return false }
                return true
            }
            var i = 0
            while i < n && !bail {
                var e = i
                while e < n && base[e] != 0x0A { e += 1 }   // \n
                var t = e
                if t > i && base[t - 1] == 0x0D { t -= 1 }  // \r
                let len = t - i
                if len > 0 {
                    if base[i] == 0x23 {                    // '#'
                        if matches(i, bSTREAMINF) || matches(i, bENDLIST)
                            || matches(i, bVOD) || matches(i, bKEY) {
                            bail = true
                        } else if matches(i, bMAP), headerEnd >= 0 {
                            bail = true                     // init segment mid-playlist
                        } else if matches(i, bDISC), len == bDISC.count {
                            // exact match only — #EXT-X-DISCONTINUITY-SEQUENCE
                            // shares this prefix and is a header tag, not a marker
                            discontinuityAt.append(i)
                        } else if matches(i, bEXTINF), headerEnd < 0 {
                            headerEnd = i
                            groupStart = i
                        }
                    } else if headerEnd >= 0 {
                        segGroupStart.append(groupStart)    // a segment URI
                        groupStart = e + 1
                    }
                }
                i = e + 1
            }
        }

        guard !bail, headerEnd > 0, segGroupStart.count > maxLiveSegments else { return data }

        let dropped = segGroupStart.count - maxLiveSegments
        let cut = segGroupStart[dropped]
        let droppedDiscontinuities = discontinuityAt.reduce(0) { $0 + ($1 < cut ? 1 : 0) }

        let headerData = data.subdata(in: data.startIndex..<(data.startIndex + headerEnd))
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        // A media playlist identifies its segments by position from
        // MEDIA-SEQUENCE, so dropping from the front without advancing it would
        // renumber every remaining segment and break continuity across reloads.
        var out: [String] = []
        var sawMediaSeq = false, sawDiscSeq = false
        for line in headerText.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.hasPrefix("#EXT-X-PROGRAM-DATE-TIME") { continue }  // belongs to a dropped segment
            if t.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                sawMediaSeq = true
                out.append("#EXT-X-MEDIA-SEQUENCE:\(intAfterColon(t) + dropped)")
            } else if t.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                sawDiscSeq = true
                out.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(intAfterColon(t) + droppedDiscontinuities)")
            } else {
                out.append(t)
            }
        }
        // Both tags default to 0 when absent, which stops being true the moment
        // anything is dropped.
        if !sawMediaSeq { out.append("#EXT-X-MEDIA-SEQUENCE:\(dropped)") }
        if !sawDiscSeq && droppedDiscontinuities > 0 {
            out.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(droppedDiscontinuities)")
        }

        var body = Data((out.joined(separator: "\n") + "\n").utf8)
        body.append(data.subdata(in: (data.startIndex + cut)..<data.endIndex))
        DebugLog.shared.log("Proxy", "PLAYLIST \(path) trimmed \(segGroupStart.count) -> "
                            + "\(maxLiveSegments) segs (\(data.count)B -> \(body.count)B, "
                            + "+\(dropped) media-seq, +\(droppedDiscontinuities) disc) "
                            + "in \(ms(since: t0))ms")
        return body
    }

    private func intAfterColon(_ tag: String) -> Int {
        guard let c = tag.range(of: ":") else { return 0 }
        return Int(tag[c.upperBound...].trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // Resolves every non-comment URI line against the playlist's own remote
    // URL and replaces it with a local proxy path, so nested playlists and
    // segments get proxied (and, if themselves playlists, rewritten again)
    // recursively.
    //
    // The variant/codec declarations are logged in this same pass rather than
    // a separate one: a VOD playlist can carry 1000+ segments, and on an
    // A4/A5 one extra walk over it is a second of dead time before playback
    // can start. The logged lines are what to compare between a device that
    // plays the item and one that doesn't.
    private func rewritePlaylist(_ data: Data, route: Route, gen: UInt64, path: String) -> Data {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let text = String(data: data, encoding: .utf8) else {
            DebugLog.shared.log("Proxy", "PLAYLIST \(path) body is not UTF-8 — probably not a playlist at all")
            return data
        }
        let tDecode = ms(since: t0)
        var uriCount = 0
        let t1 = CFAbsoluteTimeGetCurrent()
        var lines = text.components(separatedBy: "\n")
        // Only master playlists carry variants, and they are a handful of
        // lines — the extra pass is free there. A media playlist can hold
        // 1000+ segments and must stay single-pass.
        if text.range(of: "#EXT-X-STREAM-INF") != nil {
            lines = capVariants(lines, path: path)
        }
        let tSplit = ms(since: t1)
        let t2 = CFAbsoluteTimeGetCurrent()
        let baseURL = route.url
        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return line }
            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("#EXT-X-STREAM-INF") || trimmed.hasPrefix("#EXT-X-MEDIA")
                    || trimmed.hasPrefix("#EXT-X-TARGETDURATION") || trimmed.hasPrefix("#EXT-X-PLAYLIST-TYPE")
                    || trimmed.hasPrefix("#EXT-X-VERSION") {
                    DebugLog.shared.log("Proxy", "PLAYLIST \(path) | \(trimmed)")
                }
                // A variant that declares AC-3 settles the question before a
                // single segment has been fetched — and the declaration has to
                // change with it, because by the time the player reads one of
                // these segments the audio inside will be AAC.
                var line = line
                if trimmed.hasPrefix("#EXT-X-STREAM-INF"),
                   let recoded = SegmentTranscoder.rewriteCodecs(line) {
                    currentTranscoder.declareAC3()
                    line = recoded
                }
                // A tag can carry a URI in an attribute instead of on a line of
                // its own — #EXT-X-MEDIA for alternate audio or subtitles,
                // #EXT-X-KEY for an AES key, #EXT-X-MAP for an fMP4 init
                // segment. These used to be passed through untouched, so the
                // player resolved them against 127.0.0.1 and got a 404; a key
                // URI was worse still, since it sent the player at the origin
                // over the very TLS stack this proxy exists to avoid.
                guard let withLocalURI = rewriteURIAttribute(line, baseURL: baseURL,
                                                             gen: gen, headers: route.headers)
                else { return line }
                uriCount += 1
                return withLocalURI
            }
            uriCount += 1
            guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { return line }
            // Children inherit the parent's headers: the origin that demands a
            // Referer for the master playlist demands it for the segments too.
            let childIsPlaylist = LocalStreamProxy.isPlaylistURL(resolved)
            return registerPath(for: resolved, isPlaylist: childIsPlaylist,
                                gen: gen, headers: route.headers,
                                isSegment: !childIsPlaylist)
        }
        let tMap = ms(since: t2)
        let t3 = CFAbsoluteTimeGetCurrent()
        let body = Data(rewritten.joined(separator: "\n").utf8)
        // Broken down by phase because the total alone said only "too slow":
        // 21 ms per line on device, with no clue whether that was the URL
        // resolution, the dictionary bookkeeping, or Foundation string bridging.
        DebugLog.shared.log("Proxy", "PLAYLIST \(path) rewrote \(uriCount) URI(s) of "
                            + "\(lines.count) line(s) in \(ms(since: t0))ms "
                            + "[decode \(tDecode) split \(tSplit) map \(tMap) join \(ms(since: t3))]")
        return body
    }

    // Replaces the URI="..." attribute of a tag line with a local proxy path,
    // or returns nil when the line carries no such attribute — which is the
    // overwhelmingly common case, since this runs on every comment line of a
    // playlist that can hold 1000+ #EXTINF tags. NSString's search is the same
    // C-level call the hasPrefix checks above already pay for.
    private func rewriteURIAttribute(_ line: String, baseURL: URL, gen: UInt64,
                                     headers: [String: String]) -> String? {
        let s = line as NSString
        let key = s.range(of: "URI=\"")
        guard key.location != NSNotFound else { return nil }
        let start = key.location + key.length
        let close = s.range(of: "\"", options: [],
                            range: NSRange(location: start, length: s.length - start))
        guard close.location != NSNotFound else { return nil }
        let value = NSRange(location: start, length: close.location - start)
        guard value.length > 0,
              let resolved = URL(string: s.substring(with: value), relativeTo: baseURL)?.absoluteURL
        else { return nil }
        // Same inheritance rule as a bare URI line: an alternate rendition is
        // served by the origin that demanded the parent's headers.
        //
        // Not marked as a segment even when it is not a playlist: an
        // #EXT-X-KEY URI is a 16-byte key and an #EXT-X-MAP is an init segment,
        // neither of which has any audio to convert.
        let local = registerPath(for: resolved,
                                 isPlaylist: LocalStreamProxy.isPlaylistURL(resolved),
                                 gen: gen, headers: headers)
        return s.replacingCharacters(in: value, with: local)
    }

    // Drops #EXT-X-STREAM-INF variants (and their URI line) whose RESOLUTION
    // exceeds maxVariantHeight. Variants with no RESOLUTION are kept — there
    // is nothing to judge them on, and dropping them blind is worse. If every
    // variant is over the ceiling the smallest one is kept, so a stream that
    // only offers 1080p still gets a chance rather than an empty playlist.
    private func capVariants(_ lines: [String], path: String) -> [String] {
        var tagIdx: [Int] = []
        var uriIdx: [Int] = []
        var heights: [Int] = []
        var pending = -1
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("#EXT-X-STREAM-INF") { pending = i; continue }
            if t.isEmpty || t.hasPrefix("#") { continue }
            if pending >= 0 {
                tagIdx.append(pending)
                uriIdx.append(i)
                heights.append(LocalStreamProxy.resolutionHeight(lines[pending]))
                pending = -1
            }
        }
        guard !heights.isEmpty else { return lines }

        var keep = (0..<heights.count).filter { heights[$0] == 0 || heights[$0] <= maxVariantHeight }
        if keep.isEmpty, let smallest = (0..<heights.count).min(by: { heights[$0] < heights[$1] }) {
            DebugLog.shared.log("Proxy", "PLAYLIST \(path) every variant is over \(maxVariantHeight)p — keeping the smallest (\(heights[smallest])p)")
            keep = [smallest]
        }
        guard keep.count < heights.count else { return lines }

        var drop = Set<Int>()
        for v in 0..<heights.count where !keep.contains(v) {
            drop.insert(tagIdx[v])
            drop.insert(uriIdx[v])
        }
        DebugLog.shared.log("Proxy", "PLAYLIST \(path) capped variants at \(maxVariantHeight)p — dropped \(heights.count - keep.count) of \(heights.count)")
        return (0..<lines.count).filter { !drop.contains($0) }.map { lines[$0] }
    }

    // Pulls 1080 out of `...,RESOLUTION=1920x1080,CODECS=...`. 0 when absent.
    static func resolutionHeight(_ tag: String) -> Int {
        let s = tag as NSString
        let key = s.range(of: "RESOLUTION=")
        guard key.location != NSNotFound else { return 0 }
        let rest = s.substring(from: key.location + key.length) as NSString
        let x = rest.range(of: "x")
        guard x.location != NSNotFound else { return 0 }
        let after = rest.substring(from: x.location + 1)
        // The height runs to the next non-digit (comma, space, end of line).
        var digits = ""
        for ch in after {
            guard ch >= "0" && ch <= "9" else { break }
            digits.append(ch)
        }
        return Int(digits) ?? 0
    }

    // MARK: - Segments / direct streams (true streaming — relayed as they arrive)

    private func streamRemote(_ route: Route, gen: UInt64, path: String, rangeHeader: String?,
                              sniff: Bool = false, clientFd: Int32) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let remote = route.url
        let conn = ProxyConn(clientFd: clientFd, gen: gen, proxy: self)
        if sniff { conn.sniff = Data() }
        let connPtr = Unmanaged.passUnretained(conn).toOpaque()

        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        remote.absoluteString.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 0) // segments/direct streams can run far longer than a normal API call

        var headerList: UnsafeMutableRawPointer?
        if let r = rangeHeader {
            r.withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        for (k, v) in route.headers {
            "\(k): \(v)".withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { if headerList != nil { curl_bridge_headers_free(headerList) } }

        curl_bridge_set_header_fn(h, proxyHeaderCallback, connPtr)
        curl_bridge_set_write_fn(h, proxyBodyCallback, connPtr)
        curl_bridge_set_progress_fn(h, proxyProgressCallback, connPtr)

        let rc = curl_bridge_perform(h)
        let httpCode = curl_bridge_response_code(h)
        let elapsed = ms(since: t0)

        // A segment shorter than the sniff window ends without the callback
        // ever reaching the limit, so whatever was collected is judged here.
        if let prefix = conn.sniff, !prefix.isEmpty {
            conn.sniff = nil
            inspectSniff(prefix)
        }

        // Upstream said this is a playlist even though the route wasn't
        // registered as one. Relaying it verbatim would leave its relative
        // URIs pointing at paths the proxy has never heard of, so refetch it
        // through the playlist path instead (small text, cheap to redo).
        if conn.needsPlaylistRetry {
            DebugLog.shared.log("Proxy", "STREAM \(path) upstream Content-Type is a playlist — re-serving as one")
            servePlaylist(route: route, gen: gen, path: path, clientFd: clientFd)
            return
        }

        if rc != 0 && !conn.aborted {
            // rc 35 = SSL connect error — the GCM-cipher handshake smoking gun.
            // rc 28 = timeout, 7 = couldn't connect, 6 = couldn't resolve host.
            let reason = String(cString: curl_bridge_strerror(rc))
            DebugLog.shared.log("Proxy", "STREAM \(path) FAILED rc=\(rc) (\(reason)) http=\(httpCode) sent=\(conn.bytesRelayed)B in \(elapsed)ms")
        } else if conn.aborted {
            // Normal when the player seeks or closes the screen mid-segment.
            DebugLog.shared.log("Proxy", "STREAM \(path) aborted (client gone or superseded) http=\(httpCode) sent=\(conn.bytesRelayed)B in \(elapsed)ms")
        } else {
            DebugLog.shared.log("Proxy", "STREAM \(path) ok http=\(httpCode) sent=\(conn.bytesRelayed)B in \(elapsed)ms\(conn.upstreamStatus.isEmpty ? "" : " upstream=\(conn.upstreamStatus)")")
            if conn.bytesRelayed == 0 {
                DebugLog.shared.log("Proxy", "STREAM \(path) WARNING upstream returned an empty body")
            }
        }
        // If curl failed before the body callback ever ran, the client is
        // still waiting on a response head.
        if !conn.headersSent && !conn.aborted {
            sendStatusOnly(clientFd, "502 Bad Gateway")
        }
    }

    // MARK: - Raw socket send helpers

    @discardableResult
    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return true }
            return sendAll(fd, base, buf.count)
        }
    }

    @discardableResult
    static func sendAll(_ fd: Int32, _ ptr: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        guard count > 0 else { return true }
        var sent = 0
        while sent < count {
            let n = send(fd, ptr + sent, count - sent, 0)
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }
}

// MARK: - Per-connection state for the C write/header/progress callbacks
//
// Must live at file scope (not nested in LocalStreamProxy): the callbacks
// below are file-scope @convention(c) closures (C function pointers can't
// capture anything), so they reach state only via Unmanaged<ProxyConn>, and
// a file-scope closure is not an extension of LocalStreamProxy — it can't
// see that class's `private` members, only `fileprivate` ones.
private final class ProxyConn {
    let clientFd: Int32
    let gen: UInt64
    let proxy: LocalStreamProxy
    var pendingHead = ""
    var headersSent = false
    var aborted = false
    var bytesRelayed = 0
    var upstreamStatus = ""   // upstream's status line, for the log
    var upstreamIsPlaylist = false
    var needsPlaylistRetry = false

    // Copy of the first bytes of the body, kept only while the stream's audio
    // codec is still unknown, and handed to the transcoder to read the PMT out
    // of. Set to nil once used so the rest of the segment is pure relay again.
    var sniff: Data?
    static let sniffBytes = 128 * 1024

    init(clientFd: Int32, gen: UInt64, proxy: LocalStreamProxy) {
        self.clientFd = clientFd
        self.gen = gen
        self.proxy = proxy
    }
}

// Captures the upstream response's status line and headers, dropping the
// hop-by-hop ones we don't want forwarded (we always answer with our own
// Connection: close and no chunked transfer-encoding).
private let proxyHeaderCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return bytes }
    let conn = Unmanaged<ProxyConn>.fromOpaque(userdata).takeUnretainedValue()
    guard let line = String(bytes: Data(bytes: ptr, count: bytes), encoding: .isoLatin1) else { return bytes }
    let lower = line.lowercased()
    if lower.hasPrefix("http/") {
        conn.pendingHead = line // a redirect restarts the head — keep only the final one
        conn.upstreamStatus = line.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if lower.hasPrefix("transfer-encoding:") || lower.hasPrefix("connection:") {
        // dropped — we set these ourselves
    } else if lower.hasPrefix("content-type:") {
        // application/vnd.apple.mpegurl or application/x-mpegURL
        if lower.range(of: "mpegurl") != nil { conn.upstreamIsPlaylist = true }
        conn.pendingHead += line
    } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conn.pendingHead += line
    }
    return bytes
}

// Relays body bytes to the client as they arrive. Sends the buffered
// response head (built by proxyHeaderCallback) exactly once, right before
// the first body byte.
private let proxyBodyCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let conn = Unmanaged<ProxyConn>.fromOpaque(userdata).takeUnretainedValue()
    if conn.aborted { return 0 }
    // Nothing has been written to the client yet, so the whole response can
    // still be redone as a playlist — abort here and let streamRemote retry.
    if conn.upstreamIsPlaylist && !conn.headersSent {
        conn.needsPlaylistRetry = true
        conn.aborted = true
        return 0
    }
    if !conn.headersSent {
        let head = (conn.pendingHead.isEmpty ? "HTTP/1.1 200 OK\r\n" : conn.pendingHead) + "Connection: close\r\n\r\n"
        if !LocalStreamProxy.sendAll(conn.clientFd, Array(head.utf8)) {
            conn.aborted = true
            return 0
        }
        conn.headersSent = true
    }
    guard LocalStreamProxy.sendAll(conn.clientFd, ptr.assumingMemoryBound(to: UInt8.self), bytes) else {
        conn.aborted = true
        return 0
    }
    conn.bytesRelayed += bytes
    if var prefix = conn.sniff {
        prefix.append(ptr.assumingMemoryBound(to: UInt8.self), count: bytes)
        if prefix.count >= ProxyConn.sniffBytes {
            // Judged mid-segment rather than after it, so a stream that turns
            // out to be AC-3 starts converting on its *second* segment instead
            // of its third.
            conn.sniff = nil
            conn.proxy.inspectSniff(prefix)
        } else {
            conn.sniff = prefix
        }
    }
    return bytes
}

// Fires periodically during the whole transfer, including the connect/TLS
// handshake phase — returning non-zero aborts curl immediately. Used to kill
// a connection as soon as a newer playback request supersedes it, so a
// stuck/superseded transfer can't leak a blocked thread indefinitely.
private let proxyProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, _, _, _, _ in
    guard let clientp = clientp else { return 0 }
    let conn = Unmanaged<ProxyConn>.fromOpaque(clientp).takeUnretainedValue()
    if conn.aborted { return 1 }
    if conn.proxy.isSuperseded(conn.gen) {
        conn.aborted = true
        return 1
    }
    return 0
}
