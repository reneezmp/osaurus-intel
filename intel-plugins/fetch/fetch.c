// fetch.c — native x86_64 Osaurus plugin: fetch a URL.
//
// Exposes one tool, `fetch`, that GETs a URL via the host's `http_request`
// callback and returns the HTTP response envelope ({status, body, headers,
// elapsed_ms}). Very large responses are replaced with a truncation note so a
// single fetch can't blow the model's context.

#include "osaurus_plugin.h"
#include "../common/osr_jsonutil.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define FETCH_MAX_BYTES 100000  // ~100 KB cap on the returned body envelope

static const osr_host_api *g_host = NULL;

static void p_free_string(const char *s) { if (s) free((void *)s); }
static osr_plugin_ctx_t p_init(void) { static int t = 1; return (osr_plugin_ctx_t)&t; }
static void p_destroy(osr_plugin_ctx_t c) { (void)c; }

static const char *p_get_manifest(osr_plugin_ctx_t c) {
    (void)c;
    static const char *m =
        "{\"plugin_id\":\"fetch-intel\",\"name\":\"Fetch\",\"version\":\"1.0.0\","
        "\"description\":\"Fetch the contents of a URL.\","
        "\"capabilities\":{\"tools\":[{"
        "\"id\":\"fetch\","
        "\"description\":\"Fetch a web page or API endpoint over HTTP GET. Returns a JSON "
        "envelope with status, headers, and the response body (the page text/HTML or API "
        "response). Use this to read a specific known URL.\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{"
        "\"url\":{\"type\":\"string\",\"description\":\"The absolute URL to fetch (http/https).\"}"
        "},\"required\":[\"url\"]}"
        "}]}}";
    return strdup(m);
}

static const char *fail(const char *kind, const char *msg) {
    char buf[512];
    snprintf(buf, sizeof buf, "{\"ok\":false,\"kind\":\"%s\",\"message\":\"%s\"}", kind, msg);
    return strdup(buf);
}

static const char *p_invoke(osr_plugin_ctx_t c, const char *type, const char *id, const char *payload) {
    (void)c; (void)type; (void)id;

    if (!g_host || !g_host->http_request) return fail("not_supported", "http_request unavailable");

    char url[2048];
    if (!osr_json_get_string(payload ? payload : "", "url", url, sizeof url) || url[0] == '\0') {
        return fail("invalid_args", "Missing required argument 'url'.");
    }

    char url_esc[4096];
    osr_json_escape(url, url_esc, sizeof url_esc);

    char req[5120];
    snprintf(req, sizeof req,
             "{\"method\":\"GET\",\"url\":\"%s\","
             "\"headers\":{\"User-Agent\":\"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15\"},"
             "\"timeout_ms\":30000}",
             url_esc);

    const char *resp = g_host->http_request(req);
    if (!resp) return fail("execution_error", "http_request returned null");

    const char *result;
    if (strlen(resp) > FETCH_MAX_BYTES) {
        char note[256];
        snprintf(note, sizeof note,
                 "{\"ok\":true,\"truncated\":true,\"bytes\":%zu,"
                 "\"note\":\"Response too large to return in full. Fetch a more specific URL.\"}",
                 strlen(resp));
        result = strdup(note);
    } else {
        result = strdup(resp);
    }
    g_host->free_string(resp);
    return result;
}

static osr_plugin_api g_api;

const osr_plugin_api *osaurus_plugin_entry_v2(const osr_host_api *host) {
    g_host = host;
    g_api.free_string = p_free_string;
    g_api.init = p_init;
    g_api.destroy = p_destroy;
    g_api.get_manifest = p_get_manifest;
    g_api.invoke = p_invoke;
    g_api.version = OSR_ABI_VERSION_2;
    g_api.handle_route = NULL;
    g_api.on_config_changed = NULL;
    g_api.on_task_event = NULL;
    return &g_api;
}
