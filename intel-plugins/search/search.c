// search.c — native x86_64 Osaurus plugin: web search (DuckDuckGo, no API key).
//
// Exposes one tool, `web_search`, that queries DuckDuckGo's lite HTML endpoint
// via the host's `http_request` callback and parses the top results into a
// clean JSON array of {title, url, snippet}. No API key, privacy-respecting.
//
// The parser is intentionally simple (string scanning over DDG lite markup):
// each result is an `<a ... href="//duckduckgo.com/l/?uddg=<ENCODED_URL>&..."
// class='result-link'>TITLE</a>` followed by a `result-snippet` cell. If DDG
// changes its markup this may need a tweak — the tradeoff for key-free search.

#include "osaurus_plugin.h"
#include "../common/osr_jsonutil.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define SEARCH_MAX_RESULTS 8
#define SEARCH_OUT_CAP 65536

static const osr_host_api *g_host = NULL;

static void p_free_string(const char *s) { if (s) free((void *)s); }
static osr_plugin_ctx_t p_init(void) { static int t = 1; return (osr_plugin_ctx_t)&t; }
static void p_destroy(osr_plugin_ctx_t c) { (void)c; }

static const char *p_get_manifest(osr_plugin_ctx_t c) {
    (void)c;
    static const char *m =
        "{\"plugin_id\":\"search-intel\",\"name\":\"Search\",\"version\":\"1.0.0\","
        "\"description\":\"Web search via DuckDuckGo (no API key).\","
        "\"secrets\":[{\"id\":\"region\",\"label\":\"Region (DuckDuckGo kl)\","
        "\"description\":\"Optional region code, e.g. us-en, uk-en, br-pt. Blank = default.\","
        "\"required\":false,\"secret\":false,\"url\":\"https://duckduckgo.com/duckduckgo-help-pages/settings/params/\"}],"
        "\"capabilities\":{\"tools\":[{"
        "\"id\":\"web_search\","
        "\"description\":\"Search the web with DuckDuckGo and return the top results as a list "
        "of {title, url, snippet}. Use this to find current information or pages you don't "
        "already have a URL for; follow up with the fetch tool to read a result in full.\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{"
        "\"query\":{\"type\":\"string\",\"description\":\"The search query.\"}"
        "},\"required\":[\"query\"]}"
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

    char query[1024];
    if (!osr_json_get_string(payload ? payload : "", "query", query, sizeof query) || query[0] == '\0') {
        return fail("invalid_args", "Missing required argument 'query'.");
    }

    char enc[3072];
    osr_url_encode(query, enc, sizeof enc);

    // Optional user-configured region (host config; set via Plugin Settings).
    char region[64] = "";
    if (g_host->config_get) {
        const char *rv = g_host->config_get("region");
        if (rv) {
            strncpy(region, rv, sizeof region - 1);
            if (g_host->free_string) g_host->free_string(rv);
        }
    }

    char url[3300];
    if (region[0] != '\0') {
        char renc[128];
        osr_url_encode(region, renc, sizeof renc);
        snprintf(url, sizeof url, "https://lite.duckduckgo.com/lite/?q=%s&kl=%s", enc, renc);
    } else {
        snprintf(url, sizeof url, "https://lite.duckduckgo.com/lite/?q=%s", enc);
    }

    char req[3600];
    snprintf(req, sizeof req,
             "{\"method\":\"GET\",\"url\":\"%s\","
             "\"headers\":{\"User-Agent\":\"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15\"},"
             "\"timeout_ms\":30000}",
             url);

    const char *resp = g_host->http_request(req);
    if (!resp) return fail("execution_error", "http_request returned null");

    // Extract the HTML body out of the host's {status, body, ...} envelope.
    size_t cap = strlen(resp) + 1;
    char *html = malloc(cap);
    if (!html) { g_host->free_string(resp); return fail("execution_error", "out of memory"); }
    int got_body = osr_json_get_string(resp, "body", html, cap);
    g_host->free_string(resp);
    if (!got_body) { free(html); return fail("execution_error", "no body in HTTP response"); }

    char *out = malloc(SEARCH_OUT_CAP);
    if (!out) { free(html); return fail("execution_error", "out of memory"); }

    char qesc[2048];
    osr_json_escape(query, qesc, sizeof qesc);

    char resc[128];
    osr_json_escape(region, resc, sizeof resc);
    size_t oi = 0;
    oi += (size_t)snprintf(out + oi, SEARCH_OUT_CAP - oi,
                           "{\"ok\":true,\"query\":\"%s\",\"region\":\"%s\",\"results\":[", qesc, resc);

    // Each result is an `<a ... href="URL" class='result-link'>TITLE</a>`.
    // The href is either a direct URL or a `//duckduckgo.com/l/?uddg=<ENC>`
    // redirect — handle both. Snippet (if present) follows in a
    // `result-snippet` cell.
    const char *p = html;
    int n = 0;
    while (n < SEARCH_MAX_RESULTS && oi < SEARCH_OUT_CAP - 4096) {
        const char *rl = strstr(p, "result-link");
        if (!rl) break;

        // The href belonging to this anchor is the nearest `href="` before `rl`.
        const char *href = NULL, *scan = p;
        for (;;) {
            const char *h = strstr(scan, "href=\"");
            if (!h || h >= rl) break;
            href = h;
            scan = h + 6;
        }

        char rawhref[2048] = "";
        if (href) {
            const char *us = href + 6;
            const char *ue = strchr(us, '"');
            if (ue) {
                size_t len = (size_t)(ue - us);
                if (len > sizeof rawhref - 1) len = sizeof rawhref - 1;
                memcpy(rawhref, us, len);
                rawhref[len] = '\0';
            }
        }

        // Resolve the real URL: decode `uddg=` if present, else use as-is.
        char realurl[2048] = "";
        const char *uddg = strstr(rawhref, "uddg=");
        if (uddg) {
            uddg += 5;
            const char *uend = uddg;
            while (*uend && *uend != '&') uend++;
            osr_url_decode(uddg, (size_t)(uend - uddg), realurl, sizeof realurl);
        } else {
            strncpy(realurl, rawhref, sizeof realurl - 1);
        }

        // Title: anchor text from `>` after result-link up to `</a>`.
        char title[512] = "";
        const char *adv = rl + 11;
        const char *gt = strchr(rl, '>');
        if (gt) {
            const char *close = strstr(gt, "</a>");
            if (close) { osr_strip_html(gt + 1, close, title, sizeof title); adv = close + 4; }
        }

        // Snippet (best effort): `result-snippet` cell text up to `</td>`.
        char snippet[1024] = "";
        const char *sn = strstr(adv, "result-snippet");
        if (sn) {
            const char *sgt = strchr(sn, '>');
            if (sgt) {
                const char *sclose = strstr(sgt, "</td>");
                if (sclose) osr_strip_html(sgt + 1, sclose, snippet, sizeof snippet);
            }
        }

        p = adv;
        if (strncmp(realurl, "http", 4) != 0) continue;  // skip relative/non-http

        char ue[2300], te[1100], se[2200];
        osr_json_escape(realurl, ue, sizeof ue);
        osr_json_escape(title, te, sizeof te);
        osr_json_escape(snippet, se, sizeof se);

        oi += (size_t)snprintf(out + oi, SEARCH_OUT_CAP - oi,
                               "%s{\"title\":\"%s\",\"url\":\"%s\",\"snippet\":\"%s\"}",
                               n ? "," : "", te, ue, se);
        n++;
    }

    oi += (size_t)snprintf(out + oi, SEARCH_OUT_CAP - oi, "],\"count\":%d}", n);
    free(html);
    return out;  // host frees via p_free_string (free)
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
