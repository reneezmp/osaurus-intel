// search.c — native x86_64 Osaurus plugin: web search, multi-engine cascade.
//
// Exposes one tool, `web_search`, that queries multiple free search engines in
// a resilient cascade (no API key) and returns the top results as a clean JSON
// array of {rank, title, url, snippet, engine}.
//
// WHY A CASCADE: any single key-free engine anti-bots scrapers aggressively
// (DuckDuckGo's lite endpoint serves an HTTP 202 "select all squares with a
// duck" CAPTCHA under load). Relying on one engine means one challenge blanks
// the user. So we try independent engines in order — DuckDuckGo's HTML endpoint
// first (more tolerant than lite), then Bing — skipping any that get
// challenged, merging + de-duplicating what comes back, and stopping early once
// we have enough. If EVERY engine is blocked we say so explicitly (kind:
// "blocked") instead of silently returning zero results.
//
// The parsers are deliberate string-scanners over each engine's result markup
// (no regex dep). If an engine changes its markup a parser may need a tweak —
// the tradeoff for key-free search. Adding an engine = one parser + one row in
// the cascade table. (Brave + paid API backends are a planned Phase 2.)
//
// This is a native re-implementation of the soul of upstream Osaurus's Swift
// `osaurus-search` plugin (multi-backend racing search), ported to the Intel
// fork's frozen C ABI.

#include "osaurus_plugin.h"
#include "../common/osr_jsonutil.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define SEARCH_MAX_RESULTS 8     // cap returned to the caller
#define SEARCH_EARLY_EXIT  3     // stop cascading once we have >= this many hits
#define SEARCH_OUT_CAP     65536
#define HIT_TITLE_CAP      384
#define HIT_URL_CAP        1024
#define HIT_SNIPPET_CAP    512

static const osr_host_api *g_host = NULL;

static void p_free_string(const char *s) { if (s) free((void *)s); }
static osr_plugin_ctx_t p_init(void) { static int t = 1; return (osr_plugin_ctx_t)&t; }
static void p_destroy(osr_plugin_ctx_t c) { (void)c; }

static const char *p_get_manifest(osr_plugin_ctx_t c) {
    (void)c;
    static const char *m =
        "{\"plugin_id\":\"search-intel\",\"name\":\"Search\",\"version\":\"1.1.0\","
        "\"description\":\"Web search via a multi-engine cascade (DuckDuckGo + Bing, no API key).\","
        "\"secrets\":[{\"id\":\"region\",\"label\":\"Region (DuckDuckGo kl)\","
        "\"description\":\"Optional region code, e.g. us-en, uk-en, br-pt. Blank = default.\","
        "\"required\":false,\"secret\":false,\"url\":\"https://duckduckgo.com/duckduckgo-help-pages/settings/params/\"}],"
        "\"capabilities\":{\"tools\":[{"
        "\"id\":\"web_search\","
        "\"description\":\"Search the web and return the top results as a list of {title, url, "
        "snippet}. Tries multiple engines for resilience. Use this to find current information or "
        "pages you don't already have a URL for; follow up with the fetch tool to read a result in "
        "full.\","
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

// MARK: - Result type

typedef struct {
    char title[HIT_TITLE_CAP];
    char url[HIT_URL_CAP];
    char snippet[HIT_SNIPPET_CAP];
    const char *engine;
} search_hit;

// MARK: - Small string helpers

// Bounded copy of [src, src+len) into dst (NUL-terminated, truncated to cap-1).
static void copy_bounded(char *dst, const char *src, size_t len, size_t cap) {
    if (len > cap - 1) len = cap - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
}

// Decode the handful of HTML entities that show up inside URLs (chiefly &amp;).
static void decode_amp(const char *src, char *dst, size_t cap) {
    size_t i = 0;
    for (const char *p = src; *p && i + 1 < cap; ) {
        if (strncmp(p, "&amp;", 5) == 0) { dst[i++] = '&'; p += 5; }
        else if (strncmp(p, "&#38;", 5) == 0) { dst[i++] = '&'; p += 5; }
        else dst[i++] = *p++;
    }
    dst[i] = '\0';
}

// Decode base64url ([A-Za-z0-9-_], '+'/'/' also accepted) into dst. Stops at the
// first non-base64 byte or padding. Returns the number of bytes written.
static int b64url_decode(const char *in, size_t inlen, char *out, size_t cap) {
    unsigned val = 0;
    int bits = 0;
    size_t oi = 0;
    for (size_t i = 0; i < inlen; i++) {
        char c = in[i];
        int d;
        if (c >= 'A' && c <= 'Z') d = c - 'A';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 26;
        else if (c >= '0' && c <= '9') d = c - '0' + 52;
        else if (c == '-' || c == '+') d = 62;
        else if (c == '_' || c == '/') d = 63;
        else break;  // '=' padding or any other char ends the token
        val = (val << 6) | (unsigned)d;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (oi + 1 < cap) out[oi++] = (char)((val >> bits) & 0xFF);
        }
    }
    out[oi] = '\0';
    return (int)oi;
}

// Resolve a DuckDuckGo result href into a real URL: decode `uddg=<enc>` redirect
// wrappers if present, otherwise just entity-decode the direct URL.
static void resolve_ddg_url(const char *raw, char *out, size_t cap) {
    const char *uddg = strstr(raw, "uddg=");
    if (uddg) {
        uddg += 5;
        const char *end = uddg;
        while (*end && *end != '&') end++;
        osr_url_decode(uddg, (size_t)(end - uddg), out, cap);
    } else {
        decode_amp(raw, out, cap);
    }
}

// Resolve a Bing result href into a real URL: Bing wraps clicks as
// `bing.com/ck/a?...&u=a1<base64url>&ntb=1`. Decode the `u=a1…` payload; fall
// back to the raw (entity-decoded) href if it isn't a ck/a redirect.
static void resolve_bing_url(const char *raw, char *out, size_t cap) {
    const char *u = strstr(raw, "u=a1");
    if (u) {
        u += 4;  // skip "u=a1"
        const char *end = u;
        while (*end && *end != '&' && *end != '"') end++;
        char dec[1100];
        int n = b64url_decode(u, (size_t)(end - u), dec, sizeof dec);
        if (n > 4 && strncmp(dec, "http", 4) == 0) {
            copy_bounded(out, dec, (size_t)n, cap);
            return;
        }
    }
    decode_amp(raw, out, cap);
}

// Cheap anti-bot interstitial detector. Real challenge/CAPTCHA pages are tiny;
// the generic keyword markers are only trusted on small bodies because strings
// like "captcha" legitimately appear in big pages' JS (e.g. Brave's i18n dict).
static int is_challenge_page(const char *html) {
    size_t len = strlen(html);
    if (len < 2048) return 1;
    if (strstr(html, "made by a human")) return 1;  // DDG duck-CAPTCHA, any size
    if (len < 8192) {
        if (strstr(html, "Just a moment") || strstr(html, "Checking your browser")) return 1;
    }
    return 0;
}

// MARK: - Per-engine parsers
//
// Each parser scans an engine's result markup and fills up to `max` hits.
// Returns the number parsed.

// DuckDuckGo HTML endpoint: `<a class="result__a" href="URL">TITLE</a>` with an
// optional sibling `<a class="result__snippet" ...>SNIPPET</a>`. Older "lite"
// markup (`class="result-link"`) is handled as a fallback when result__a is
// absent.
static int parse_ddg(const char *html, search_hit *hits, int max) {
    int n = 0;
    const char *p = html;
    while (n < max) {
        const char *a = strstr(p, "result__a");
        if (!a) break;

        const char *gt = strchr(a, '>');
        const char *href = strstr(a, "href=\"");
        if (!href || (gt && href > gt)) { p = a + 9; continue; }
        href += 6;
        const char *he = strchr(href, '"');
        if (!he) break;

        char rawurl[HIT_URL_CAP];
        copy_bounded(rawurl, href, (size_t)(he - href), sizeof rawurl);

        const char *tstart = (gt && gt > he) ? gt + 1 : he + 1;
        const char *tend = strstr(tstart, "</a>");
        char title[HIT_TITLE_CAP] = "";
        if (tend) osr_strip_html(tstart, tend, title, sizeof title);

        // Snippet, only if it belongs to THIS result (precedes the next result__a).
        char snippet[HIT_SNIPPET_CAP] = "";
        const char *scan = tend ? tend : a;
        const char *sn = strstr(scan, "result__snippet");
        const char *nexta = strstr(scan, "result__a");
        if (sn && (!nexta || sn < nexta)) {
            const char *sgt = strchr(sn, '>');
            if (sgt) {
                const char *sclose = strstr(sgt, "</a>");
                if (sclose) osr_strip_html(sgt + 1, sclose, snippet, sizeof snippet);
            }
        }

        char realurl[HIT_URL_CAP];
        resolve_ddg_url(rawurl, realurl, sizeof realurl);

        p = tend ? tend + 4 : he + 1;
        if (strncmp(realurl, "http", 4) != 0 || title[0] == '\0') continue;

        copy_bounded(hits[n].title, title, strlen(title), sizeof hits[n].title);
        copy_bounded(hits[n].url, realurl, strlen(realurl), sizeof hits[n].url);
        copy_bounded(hits[n].snippet, snippet, strlen(snippet), sizeof hits[n].snippet);
        hits[n].engine = "ddg";
        n++;
    }
    return n;
}

// Bing: `<li class="b_algo">…<h2><a href="URL">TITLE</a></h2>…<p class="b_lineclamp…">SNIPPET</p>`.
static int parse_bing(const char *html, search_hit *hits, int max) {
    int n = 0;
    const char *p = html;
    while (n < max) {
        const char *li = strstr(p, "b_algo");
        if (!li) break;
        const char *nextli = strstr(li + 6, "b_algo");

        const char *h2 = strstr(li, "<h2");
        if (!h2 || (nextli && h2 > nextli)) { p = li + 6; continue; }

        const char *href = strstr(h2, "href=\"");
        if (!href || (nextli && href > nextli)) { p = nextli ? nextli : (li + 6); continue; }
        href += 6;
        const char *he = strchr(href, '"');
        if (!he) break;

        char rawurl[HIT_URL_CAP * 2];  // ck/a redirects are long
        copy_bounded(rawurl, href, (size_t)(he - href), sizeof rawurl);

        const char *agt = strchr(he, '>');
        char title[HIT_TITLE_CAP] = "";
        if (agt) {
            const char *tend = strstr(agt, "</a>");
            if (tend) osr_strip_html(agt + 1, tend, title, sizeof title);
        }

        // Snippet: first <p class="..."> after the h2, bounded to this result.
        char snippet[HIT_SNIPPET_CAP] = "";
        const char *pp = strstr(h2, "<p");
        if (pp && (!nextli || pp < nextli)) {
            const char *pgt = strchr(pp, '>');
            if (pgt) {
                const char *pend = strstr(pgt, "</p>");
                if (pend) osr_strip_html(pgt + 1, pend, snippet, sizeof snippet);
            }
        }

        char realurl[HIT_URL_CAP];
        resolve_bing_url(rawurl, realurl, sizeof realurl);

        p = nextli ? nextli : (he + 1);
        if (strncmp(realurl, "http", 4) != 0 || title[0] == '\0') continue;

        copy_bounded(hits[n].title, title, strlen(title), sizeof hits[n].title);
        copy_bounded(hits[n].url, realurl, strlen(realurl), sizeof hits[n].url);
        copy_bounded(hits[n].snippet, snippet, strlen(snippet), sizeof hits[n].snippet);
        hits[n].engine = "bing";
        n++;
    }
    return n;
}

// MARK: - Host HTTP

// GET `url` through the host. On success returns a malloc'd HTML body (caller
// frees) and writes the HTTP status to *status. On failure returns NULL and
// writes a short reason into err.
static char *host_get(const char *url, long *status, char *err, size_t errcap) {
    *status = 0;
    if (errcap) err[0] = '\0';
    if (!g_host || !g_host->http_request) {
        snprintf(err, errcap, "http_request unavailable");
        return NULL;
    }

    char req[3600];
    snprintf(req, sizeof req,
             "{\"method\":\"GET\",\"url\":\"%s\","
             "\"headers\":{\"User-Agent\":\"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15\","
             "\"Accept\":\"text/html\",\"Accept-Language\":\"en-US,en;q=0.9\"},"
             "\"timeout_ms\":15000}",
             url);

    const char *resp = g_host->http_request(req);
    if (!resp) { snprintf(err, errcap, "http_request returned null"); return NULL; }

    // Host error envelope ({"error","message"}) — surface it verbatim.
    char herr[128];
    if (osr_json_get_string(resp, "error", herr, sizeof herr)) {
        char hmsg[256];
        if (!osr_json_get_string(resp, "message", hmsg, sizeof hmsg)) hmsg[0] = '\0';
        snprintf(err, errcap, "%s%s%s", herr, hmsg[0] ? ": " : "", hmsg);
        g_host->free_string(resp);
        return NULL;
    }

    osr_json_get_int(resp, "status", status);

    size_t cap = strlen(resp) + 1;
    char *html = malloc(cap);
    if (!html) { g_host->free_string(resp); snprintf(err, errcap, "out of memory"); return NULL; }
    int got_body = osr_json_get_string(resp, "body", html, cap);
    g_host->free_string(resp);
    if (!got_body) { free(html); snprintf(err, errcap, "no body in HTTP response"); return NULL; }
    return html;
}

// MARK: - Cascade

typedef int (*parser_fn)(const char *html, search_hit *hits, int max);

typedef struct {
    const char *name;
    parser_fn parse;
} engine_def;

// Build an engine's request URL into `url`. `enc` is the URL-encoded query;
// `region` is an optional DDG kl code ("" for none).
static void build_engine_url(const char *name, const char *enc, const char *region,
                             char *url, size_t cap) {
    if (strcmp(name, "ddg") == 0) {
        if (region[0]) {
            char renc[128];
            osr_url_encode(region, renc, sizeof renc);
            snprintf(url, cap, "https://html.duckduckgo.com/html/?q=%s&kl=%s", enc, renc);
        } else {
            snprintf(url, cap, "https://html.duckduckgo.com/html/?q=%s&kl=wt-wt", enc);
        }
    } else {  // bing
        snprintf(url, cap, "https://www.bing.com/search?q=%s&count=%d", enc, SEARCH_MAX_RESULTS);
    }
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

    const engine_def engines[] = {
        { "ddg", parse_ddg },
        { "bing", parse_bing },
    };
    const int n_engines = (int)(sizeof engines / sizeof engines[0]);

    search_hit *merged = malloc(sizeof(search_hit) * SEARCH_MAX_RESULTS);
    if (!merged) return fail("execution_error", "out of memory");
    int total = 0;
    const char *provider = "";

    // Per-engine attempt log (only emitted on failure, where it's actionable).
    char attempts[1024];
    size_t aj = 0;
    attempts[0] = '\0';
    int blocked_count = 0, tried = 0;

    search_hit *batch = malloc(sizeof(search_hit) * SEARCH_MAX_RESULTS);
    if (!batch) { free(merged); return fail("execution_error", "out of memory"); }

    for (int e = 0; e < n_engines && total < SEARCH_EARLY_EXIT; e++) {
        char url[3300];
        build_engine_url(engines[e].name, enc, region, url, sizeof url);

        long status = 0;
        char err[256];
        char *html = host_get(url, &status, err, sizeof err);

        char ename[16];
        osr_json_escape(engines[e].name, ename, sizeof ename);
        tried++;

        if (!html) {
            char ee[300];
            osr_json_escape(err, ee, sizeof ee);
            aj += (size_t)snprintf(attempts + aj, sizeof attempts - aj,
                                   "%s{\"engine\":\"%s\",\"ok\":false,\"error\":\"%s\"}",
                                   aj ? "," : "", ename, ee);
            continue;
        }
        if (status != 200 || is_challenge_page(html)) {
            blocked_count++;
            aj += (size_t)snprintf(attempts + aj, sizeof attempts - aj,
                                   "%s{\"engine\":\"%s\",\"ok\":false,\"error\":\"blocked\",\"status\":%ld}",
                                   aj ? "," : "", ename, status);
            free(html);
            continue;
        }

        int got = engines[e].parse(html, batch, SEARCH_MAX_RESULTS);
        free(html);

        aj += (size_t)snprintf(attempts + aj, sizeof attempts - aj,
                               "%s{\"engine\":\"%s\",\"ok\":true,\"count\":%d}",
                               aj ? "," : "", ename, got);

        // Merge with de-duplication (case-insensitive URL match).
        for (int i = 0; i < got && total < SEARCH_MAX_RESULTS; i++) {
            int dup = 0;
            for (int j = 0; j < total; j++) {
                if (strcasecmp(batch[i].url, merged[j].url) == 0) { dup = 1; break; }
            }
            if (dup) continue;
            merged[total] = batch[i];
            if (provider[0] == '\0') provider = engines[e].name;
            total++;
        }
    }
    free(batch);

    // No results: distinguish "everything was blocked" from "genuinely nothing".
    if (total == 0) {
        free(merged);
        char qesc[2048];
        osr_json_escape(query, qesc, sizeof qesc);
        char buf[2048];
        if (blocked_count == tried && tried > 0) {
            snprintf(buf, sizeof buf,
                     "{\"ok\":false,\"kind\":\"blocked\",\"query\":\"%s\","
                     "\"message\":\"Every search engine was rate-limited or blocked. "
                     "Wait a bit and retry.\",\"attempts\":[%s]}",
                     qesc, attempts);
        } else {
            snprintf(buf, sizeof buf,
                     "{\"ok\":false,\"kind\":\"no_results\",\"query\":\"%s\","
                     "\"message\":\"No results from any engine. Try a broader query.\","
                     "\"attempts\":[%s]}",
                     qesc, attempts);
        }
        return strdup(buf);
    }

    // Success: emit results. `attempts` is intentionally omitted from the happy
    // path — leaking per-engine ok:false entries makes tool-call UIs flag a
    // successful search as failed.
    char *out = malloc(SEARCH_OUT_CAP);
    if (!out) { free(merged); return fail("execution_error", "out of memory"); }

    char qesc[2048], pesc[32];
    osr_json_escape(query, qesc, sizeof qesc);
    osr_json_escape(provider, pesc, sizeof pesc);
    size_t oi = 0;
    oi += (size_t)snprintf(out + oi, SEARCH_OUT_CAP - oi,
                           "{\"ok\":true,\"query\":\"%s\",\"provider\":\"%s\",\"results\":[",
                           qesc, pesc);

    for (int i = 0; i < total && oi < SEARCH_OUT_CAP - 4096; i++) {
        char te[HIT_TITLE_CAP * 2], ue[HIT_URL_CAP * 2], se[HIT_SNIPPET_CAP * 2], ge[32];
        osr_json_escape(merged[i].title, te, sizeof te);
        osr_json_escape(merged[i].url, ue, sizeof ue);
        osr_json_escape(merged[i].snippet, se, sizeof se);
        osr_json_escape(merged[i].engine, ge, sizeof ge);
        oi += (size_t)snprintf(out + oi, SEARCH_OUT_CAP - oi,
                               "%s{\"rank\":%d,\"title\":\"%s\",\"url\":\"%s\",\"snippet\":\"%s\","
                               "\"engine\":\"%s\"}",
                               i ? "," : "", i + 1, te, ue, se, ge);
    }
    oi += (size_t)snprintf(out + oi, SEARCH_OUT_CAP - oi, "],\"count\":%d}", total);

    free(merged);
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
