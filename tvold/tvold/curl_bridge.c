#include "curl_bridge.h"
#include <curl/curl.h>
#include <pthread.h>

/* Shared DNS/connection/TLS-session cache across every easy handle, so
   concurrent proxy connections to the same Jellyfin host reuse lookups and
   handshakes instead of redoing them per-connection. libcurl nests locks of
   DIFFERENT types while sharing (e.g. holds CONNECT while taking DNS or
   SSL_SESSION), so this needs one mutex PER lock-data type, not one mutex
   for all of them — a single shared mutex self-deadlocks on the first
   transfer. */
static CURLSH *g_share = NULL;
static pthread_mutex_t g_share_locks[CURL_LOCK_DATA_LAST];

static void curl_bridge_share_lock(CURL *handle, curl_lock_data data, curl_lock_access access, void *userptr) {
    (void)handle; (void)access; (void)userptr;
    if (data >= 0 && data < CURL_LOCK_DATA_LAST) pthread_mutex_lock(&g_share_locks[data]);
}

static void curl_bridge_share_unlock(CURL *handle, curl_lock_data data, void *userptr) {
    (void)handle; (void)userptr;
    if (data >= 0 && data < CURL_LOCK_DATA_LAST) pthread_mutex_unlock(&g_share_locks[data]);
}

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
    for (int i = 0; i < CURL_LOCK_DATA_LAST; i++) {
        pthread_mutex_init(&g_share_locks[i], NULL);
    }
    g_share = curl_share_init();
    if (g_share) {
        curl_share_setopt(g_share, CURLSHOPT_LOCKFUNC, curl_bridge_share_lock);
        curl_share_setopt(g_share, CURLSHOPT_UNLOCKFUNC, curl_bridge_share_unlock);
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT);
        curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
    }
}

CurlHandle curl_bridge_init(void) {
    CURL *e = curl_easy_init();
    if (e) {
        /* Required whenever curl_easy_perform runs off the main thread: with
           the synchronous resolver, libcurl times out DNS/connect via
           SIGALRM/alarm(); perform() racing across threads without this can
           hang up to the full timeout. */
        curl_easy_setopt(e, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(e, CURLOPT_CONNECTTIMEOUT, 15L);
        if (g_share) curl_easy_setopt(e, CURLOPT_SHARE, g_share);
    }
    return e;
}

void curl_bridge_cleanup(CurlHandle h) {
    curl_easy_cleanup(h);
}

void curl_bridge_set_url(CurlHandle h, const char *url) {
    curl_easy_setopt(h, CURLOPT_URL, url);
}

void curl_bridge_set_ssl_noverify(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST, 0L);
}

void curl_bridge_set_follow_redirects(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(h, CURLOPT_MAXREDIRS, 10L);
}

void curl_bridge_set_timeout(CurlHandle h, long secs) {
    curl_easy_setopt(h, CURLOPT_TIMEOUT, secs);
}

void curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata) {
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, userdata);
}

void curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp) {
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, clientp);
}

void curl_bridge_set_header_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata) {
    curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_HEADERDATA, userdata);
}

/* POSTFIELDSIZE must be set before COPYPOSTFIELDS so curl copies exactly len
   bytes (the body is not NUL-terminated). COPYPOSTFIELDS also switches the
   method to POST and takes its own copy, so the caller's buffer can be freed
   immediately after this call. */
void curl_bridge_set_post_body(CurlHandle h, const void *body, long len) {
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, len);
    curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, body);
}

void *curl_bridge_headers_append(void *list, const char *header) {
    return curl_slist_append((struct curl_slist *)list, header);
}

void curl_bridge_set_headers(CurlHandle h, void *list) {
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, (struct curl_slist *)list);
}

void curl_bridge_headers_free(void *list) {
    curl_slist_free_all((struct curl_slist *)list);
}

int curl_bridge_perform(CurlHandle h) {
    return (int)curl_easy_perform(h);
}

long curl_bridge_response_code(CurlHandle h) {
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *curl_bridge_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}
