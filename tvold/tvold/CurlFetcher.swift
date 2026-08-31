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

// Accumulates a file download into an open FileHandle, passed via userdata.
private let curlFileWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(userdata).takeUnretainedValue()
    box.fileHandle?.write(Data(bytes: ptr, count: bytes))
    box.bytesReceived += Int64(bytes)
    return bytes
}

// Reports download progress (0...1) back to the main thread.
private let curlProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, dltotal, dlnow, _, _ in
    guard let clientp = clientp, dltotal > 0 else { return 0 }
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(clientp).takeUnretainedValue()
    let progress = Float(dlnow) / Float(dltotal)
    DispatchQueue.main.async { box.progressHandler?(progress) }
    return 0
}

private class CurlDownloadBox {
    var fileHandle: FileHandle?
    var bytesReceived: Int64 = 0
    var progressHandler: ((Float) -> Void)?
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
    // completion on the main thread. Used by DownloadManager.
    static func downloadToFile(url: String,
                               outputPath: String,
                               progress: ((Float) -> Void)?,
                               completion: @escaping (Bool) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.downloadQueue.async {
            let ok = fetcher.syncDownload(url: url, outputPath: outputPath, progress: progress)
            DispatchQueue.main.async {
                release(fetcher)
                completion(ok)
            }
        }
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

    // No CURLOPT_TIMEOUT (secs: 0 = unbounded) — movie downloads can run far longer
    // than an API call, and a total-time cap would abort a large file mid-transfer.
    private func syncDownload(url: String, outputPath: String, progress: ((Float) -> Void)?) -> Bool {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
        guard let fh = FileHandle(forWritingAtPath: outputPath) else { return false }
        let box = CurlDownloadBox()
        box.fileHandle = fh
        box.progressHandler = progress
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 0)
        curl_bridge_set_write_fn(h, curlFileWriteCallback, boxPtr)
        if progress != nil { curl_bridge_set_progress_fn(h, curlProgressCallback, boxPtr) }

        let rc = curl_bridge_perform(h)
        fh.closeFile()
        guard rc == 0 else {
            try? FileManager.default.removeItem(atPath: outputPath)
            return false
        }
        let code = curl_bridge_response_code(h)
        guard code >= 200, code < 300 else {
            try? FileManager.default.removeItem(atPath: outputPath)
            return false
        }
        return box.bytesReceived > 0
    }
}
