import Foundation

// MARK: - C-compatible write callback (file scope, no captures allowed)

// Accumulates the HTTP response body into an NSMutableData passed via userdata.
private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let buf = Unmanaged<NSMutableData>.fromOpaque(userdata).takeUnretainedValue()
    buf.append(ptr, length: bytes)
    return bytes
}

// Writes a file download straight to a file descriptor passed via userdata.
//
// A raw POSIX fd, not a FileHandle: the Foundation file-write overlay kills the
// process mid-write on the shipped 5.1.5 runtime. See DebugLog and LogoCache,
// which were moved off it for the same reason.
private let curlFileWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(userdata).takeUnretainedValue()
    guard box.fd >= 0 else { return 0 }
    // Returning short tells libcurl the write failed and aborts the transfer,
    // which is what should happen if the disk is full.
    guard write(box.fd, ptr, bytes) == bytes else { return 0 }
    box.bytesReceived += Int64(bytes)
    return bytes
}

// Reports download progress (0...1) back to the main thread, and is also the
// only place a transfer in progress can be cancelled: returning non-zero makes
// libcurl abort. libcurl calls this even before the size is known, so the
// cancel check has to come before the dltotal guard.
private let curlProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, dltotal, dlnow, _, _ in
    guard let clientp = clientp else { return 0 }
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(clientp).takeUnretainedValue()
    if box.cancelled { return 1 }
    guard dltotal > 0 else { return 0 }
    let progress = Float(dlnow) / Float(dltotal)
    DispatchQueue.main.async { box.progressHandler?(progress) }
    return 0
}

private class CurlDownloadBox {
    var fd: Int32 = -1
    var bytesReceived: Int64 = 0
    var progressHandler: ((Float) -> Void)?
    // Set from the main thread while the transfer runs on a background queue.
    // A plain Bool: the read is a single word and a late observation only costs
    // one more progress tick before the transfer stops.
    var cancelled = false
}

// Opaque handle letting a caller abort a download it has already started.
final class CurlDownloadToken {
    fileprivate weak var box: CurlDownloadBox?
    func cancel() { box?.cancelled = true }
}

// MARK: - CurlFetcher
//
// libcurl + embedded OpenSSL transport. Bypasses iOS 6 Secure Transport, which
// only negotiates CBC cipher suites — modern Jellyfin servers behind HTTPS
// (and any reverse proxy enforcing GCM-only TLS) fail the handshake under
// NSURLConnection on iOS 6. OpenSSL negotiates GCM correctly, so HTTPS logins
// work while plain HTTP logins keep working unchanged.

class CurlFetcher {
    private static var active: [CurlFetcher] = []
    // Serial queue — serial prevents concurrent curl_easy_init before global init.
    // curl_global_init is NOT thread-safe; concurrent implicit calls via curl_easy_init crash.
    private static let curlQueue = DispatchQueue(label: "com.jellyold.curl")
    // Dedicated serial queue for file downloads, kept separate from curlQueue so a
    // multi-GB movie download never blocks API calls or thumbnail fetches.
    private static let downloadQueue = DispatchQueue(label: "com.jellyold.curl.download")
    // Thread-safe once-init: Swift static let uses dispatch_once. The first
    // background thread to touch this runs curl_global_init exactly once.
    // Never run from the main thread (crashes — OpenSSL threading init).
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    // Ensures curl_global_init has run. Callers driving libcurl directly on
    // their own background threads (e.g. the streaming proxy's per-connection
    // threads) must call this before their first curl_bridge_init(), same as
    // every method below does implicitly.
    static func ensureGlobalInit() {
        _ = curlGlobalInit
    }

    // Synchronous GET -> Data. Caller must already be off the main thread
    // (curl_global_init crashes if triggered there). Used by the streaming
    // proxy for playlist fetches, which need the whole body to rewrite URIs.
    static func fetchSyncData(url: String, headers: [String: String] = [:], timeout: Int = 30) -> Data? {
        _ = curlGlobalInit
        return CurlFetcher().syncFetchData(url: url, headers: headers, timeout: timeout)
    }

    // GET url -> Data on a background thread; completion on the main thread.
    static func fetchData(url: String,
                          headers: [String: String] = [:],
                          timeout: Int = 30,
                          completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
            let data = fetcher.syncFetchData(url: url, headers: headers, timeout: timeout)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data)
            }
        }
    }

    // POST url with JSON body + custom headers -> Data on a background thread;
    // completion on the main thread. Used by the login path.
    static func postData(url: String,
                         headers: [String: String],
                         body: Data,
                         timeout: Int = 30,
                         completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
            let data = fetcher.syncPostData(url: url, headers: headers, body: body, timeout: timeout)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data)
            }
        }
    }

    // Download url -> local file with progress, on the dedicated download queue;
    // completion on the main thread. The returned token can cancel it.
    @discardableResult
    static func downloadToFile(url: String,
                               outputPath: String,
                               timeout: Int = 0,
                               progress: ((Float) -> Void)?,
                               completion: @escaping (Bool) -> Void) -> CurlDownloadToken {
        let fetcher = CurlFetcher()
        let token = CurlDownloadToken()
        retain(fetcher)
        CurlFetcher.downloadQueue.async {
            let ok = fetcher.syncDownload(url: url, outputPath: outputPath,
                                          timeout: timeout, progress: progress, token: token)
            DispatchQueue.main.async {
                release(fetcher)
                completion(ok)
            }
        }
        return token
    }

    // MARK: - Lifecycle management

    private static func retain(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.append(f)
        objc_sync_exit(CurlFetcher.self)
    }

    private static func release(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.removeAll { $0 === f }
        objc_sync_exit(CurlFetcher.self)
    }

    // MARK: - Synchronous implementations (run on the background queue)

    private func syncFetchData(url: String, headers: [String: String], timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit  // ensures curl_global_init ran once before any easy_init
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        var headerList: UnsafeMutableRawPointer?
        for (k, v) in headers {
            "\(k): \(v)".withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { if headerList != nil { curl_bridge_headers_free(headerList) } }

        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return nil }
        let code = curl_bridge_response_code(h)
        guard code >= 200, code < 300 else { return nil }
        return buf as Data
    }

    private func syncPostData(url: String, headers: [String: String], body: Data, timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        var headerList: UnsafeMutableRawPointer?
        for (k, v) in headers {
            "\(k): \(v)".withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { if headerList != nil { curl_bridge_headers_free(headerList) } }

        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            curl_bridge_set_post_body(h, raw.baseAddress, CLong(body.count))
        }

        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return nil }
        let code = curl_bridge_response_code(h)
        guard code >= 200, code < 300 else { return nil }
        return buf as Data
    }

    // timeout 0 means no CURLOPT_TIMEOUT at all — a total-time cap would abort a
    // large file mid-transfer on a slow connection, so callers fetching
    // something open-ended leave it at 0 and rely on cancellation instead.
    private func syncDownload(url: String, outputPath: String, timeout: Int,
                              progress: ((Float) -> Void)?, token: CurlDownloadToken) -> Bool {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let fd = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        let box = CurlDownloadBox()
        box.fd = fd
        box.progressHandler = progress
        token.box = box
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlFileWriteCallback, boxPtr)
        // Always installed, not just when there is a progress handler — it is
        // also the cancellation hook.
        curl_bridge_set_progress_fn(h, curlProgressCallback, boxPtr)

        let rc = curl_bridge_perform(h)
        close(fd)
        box.fd = -1

        // A partial file is worse than none: the next stage would parse it and
        // report corrupt data rather than a failed download.
        func fail() -> Bool {
            try? FileManager.default.removeItem(atPath: outputPath)
            return false
        }
        guard rc == 0 else { return fail() }
        let code = curl_bridge_response_code(h)
        guard code >= 200, code < 300 else { return fail() }
        guard box.bytesReceived > 0 else { return fail() }
        return true
    }
}
