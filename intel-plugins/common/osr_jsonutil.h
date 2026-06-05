// osr_jsonutil.h — tiny header-only helpers shared by the Intel C plugins.
// JSON string extraction/escaping + URL encode/decode + HTML text extraction.
// Deliberately minimal (no deps beyond libc); good enough for plugin payloads
// and DuckDuckGo lite scraping, not a general-purpose JSON/HTML library.

#ifndef OSR_JSONUTIL_H
#define OSR_JSONUTIL_H

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

// Extract the JSON string value for `key` from `json` into `out`.
// Returns 1 on success, 0 if the key is absent or not a string.
static int osr_json_get_string(const char *json, const char *key, char *out, size_t outsz) {
    if (!json || !key || !out || outsz == 0) return 0;
    char pat[128];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return 0;
    p += strlen(pat);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != ':') return 0;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < outsz) {
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n': out[i++] = '\n'; break;
                case 't': out[i++] = '\t'; break;
                case 'r': out[i++] = '\r'; break;
                case '"': out[i++] = '"'; break;
                case '\\': out[i++] = '\\'; break;
                case '/': out[i++] = '/'; break;
                case 'u': if (p[1] && p[2] && p[3] && p[4]) p += 4; out[i++] = '?'; break;
                default: out[i++] = *p; break;
            }
            p++;
        } else {
            out[i++] = *p++;
        }
    }
    out[i] = '\0';
    return 1;
}

// Escape `in` as a JSON string body (no surrounding quotes) into `out`.
static void osr_json_escape(const char *in, char *out, size_t outsz) {
    size_t i = 0;
    if (!in) { if (outsz) out[0] = '\0'; return; }
    for (const char *p = in; *p && i + 7 < outsz; p++) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"':  out[i++] = '\\'; out[i++] = '"'; break;
            case '\\': out[i++] = '\\'; out[i++] = '\\'; break;
            case '\n': out[i++] = '\\'; out[i++] = 'n'; break;
            case '\r': out[i++] = '\\'; out[i++] = 'r'; break;
            case '\t': out[i++] = '\\'; out[i++] = 't'; break;
            default:
                if (c < 0x20) { i += (size_t)snprintf(out + i, outsz - i, "\\u%04x", c); }
                else out[i++] = (char)c;
        }
    }
    out[i] = '\0';
}

// Percent-encode `in` for use in a URL query into `out`.
static void osr_url_encode(const char *in, char *out, size_t outsz) {
    static const char hex[] = "0123456789ABCDEF";
    size_t i = 0;
    if (!in) { if (outsz) out[0] = '\0'; return; }
    for (const char *p = in; *p && i + 4 < outsz; p++) {
        unsigned char c = (unsigned char)*p;
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out[i++] = (char)c;
        } else {
            out[i++] = '%'; out[i++] = hex[c >> 4]; out[i++] = hex[c & 15];
        }
    }
    out[i] = '\0';
}

// Percent-decode the first `inlen` bytes of `in` into `out`.
static void osr_url_decode(const char *in, size_t inlen, char *out, size_t outsz) {
    size_t i = 0, j = 0;
    while (j < inlen && in[j] && i + 1 < outsz) {
        if (in[j] == '%' && j + 2 < inlen && isxdigit((unsigned char)in[j + 1]) && isxdigit((unsigned char)in[j + 2])) {
            char h[3] = { in[j + 1], in[j + 2], 0 };
            out[i++] = (char)strtol(h, NULL, 16);
            j += 3;
        } else if (in[j] == '+') {
            out[i++] = ' '; j++;
        } else {
            out[i++] = in[j++];
        }
    }
    out[i] = '\0';
}

// Copy text in [start, end) into `out`, stripping `<...>` tags and decoding a
// handful of common HTML entities. Used to clean DDG result titles/snippets.
static void osr_strip_html(const char *start, const char *end, char *out, size_t outsz) {
    size_t i = 0;
    int intag = 0;
    for (const char *p = start; p < end && i + 1 < outsz; p++) {
        if (*p == '<') { intag = 1; continue; }
        if (*p == '>') { intag = 0; continue; }
        if (intag) continue;
        out[i++] = *p;
    }
    out[i] = '\0';

    // Minimal entity decode (in place, shrinking).
    static const char *ents[][2] = {
        { "&amp;", "&" }, { "&lt;", "<" }, { "&gt;", ">" },
        { "&quot;", "\"" }, { "&#x27;", "'" }, { "&#39;", "'" }, { "&nbsp;", " " },
    };
    for (size_t e = 0; e < sizeof(ents) / sizeof(ents[0]); e++) {
        const char *from = ents[e][0];
        const char *to = ents[e][1];
        size_t flen = strlen(from), tlen = strlen(to);
        char *pos;
        while ((pos = strstr(out, from)) != NULL) {
            memmove(pos + tlen, pos + flen, strlen(pos + flen) + 1);
            memcpy(pos, to, tlen);
        }
    }

    // Collapse runs of whitespace to a single space and trim the ends, so
    // scraped titles/snippets come back as tidy single-line text.
    {
        size_t w = 0;
        int prev_space = 1;  // leading-trim: treat start as preceded by space
        for (size_t r = 0; out[r]; r++) {
            unsigned char c = (unsigned char)out[r];
            int is_space = (c == ' ' || c == '\t' || c == '\n' || c == '\r');
            if (is_space) {
                if (!prev_space) out[w++] = ' ';
                prev_space = 1;
            } else {
                out[w++] = (char)c;
                prev_space = 0;
            }
        }
        while (w > 0 && out[w - 1] == ' ') w--;  // trailing-trim
        out[w] = '\0';
    }
}

#endif // OSR_JSONUTIL_H
