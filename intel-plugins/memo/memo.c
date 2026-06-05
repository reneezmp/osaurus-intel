// memo.c — native x86_64 Osaurus plugin: persistent notes + background runner.
//
// Demonstrates the upgraded slim host:
//   • db_exec / db_query  → per-plugin SQLite storage (memo_save/list/clear)
//   • dispatch            → spawn a background agent task (run_background)
//   • manifest instructions → injected into the system prompt when active
//
// Storage lives at ~/.osaurus-intel/Tools/memo-intel/plugin.db.

#include "osaurus_plugin.h"
#include "../common/osr_jsonutil.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static const osr_host_api *g_host = NULL;

static void p_free_string(const char *s) { if (s) free((void *)s); }
static osr_plugin_ctx_t p_init(void) { static int t = 1; return (osr_plugin_ctx_t)&t; }
static void p_destroy(osr_plugin_ctx_t c) { (void)c; }

static const char *p_get_manifest(osr_plugin_ctx_t c) {
    (void)c;
    static const char *m =
        "{\"plugin_id\":\"memo-intel\",\"name\":\"Memo\",\"version\":\"1.0.0\","
        "\"description\":\"Persistent notes + background task runner.\","
        "\"instructions\":\"You can persist short notes for the user with the memo tools "
        "(memo_save/memo_list/memo_clear), which survive across sessions. When the user asks "
        "you to remember something, save it; when they ask what they told you to remember, "
        "list it. Use run_background to kick off a long task without blocking the chat.\","
        "\"capabilities\":{\"tools\":["
        "{\"id\":\"memo_save\",\"description\":\"Persist a note for later.\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"The note to remember.\"}},\"required\":[\"text\"]}},"
        "{\"id\":\"memo_list\",\"description\":\"List saved notes (most recent first).\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},"
        "{\"id\":\"memo_clear\",\"description\":\"Delete all saved notes.\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}},"
        "{\"id\":\"run_background\",\"description\":\"Spawn a background agent task with the given prompt.\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{\"prompt\":{\"type\":\"string\",\"description\":\"What the background agent should do.\"}},\"required\":[\"prompt\"]}}"
        "]}}";
    return strdup(m);
}

static const char *fail(const char *kind, const char *msg) {
    char buf[512];
    snprintf(buf, sizeof buf, "{\"ok\":false,\"kind\":\"%s\",\"message\":\"%s\"}", kind, msg);
    return strdup(buf);
}

// Copy a host-returned string into a plugin-owned result, freeing the host's.
static const char *take(const char *hostResult) {
    const char *out = strdup(hostResult ? hostResult : "{\"ok\":false,\"message\":\"null host result\"}");
    if (hostResult && g_host && g_host->free_string) g_host->free_string(hostResult);
    return out;
}

static void ensure_table(void) {
    if (!g_host || !g_host->db_exec) return;
    const char *r = g_host->db_exec(
        "CREATE TABLE IF NOT EXISTS memos(id INTEGER PRIMARY KEY AUTOINCREMENT, "
        "text TEXT NOT NULL, created INTEGER)", NULL);
    if (r && g_host->free_string) g_host->free_string(r);
}

static const char *p_invoke(osr_plugin_ctx_t c, const char *type, const char *id, const char *payload) {
    (void)c; (void)type;
    if (!id) return fail("invalid_args", "missing tool id");
    if (!g_host) return fail("not_supported", "host unavailable");

    if (strcmp(id, "memo_save") == 0) {
        if (!g_host->db_exec) return fail("not_supported", "db unavailable");
        char text[2048];
        if (!osr_json_get_string(payload ? payload : "", "text", text, sizeof text) || text[0] == '\0')
            return fail("invalid_args", "Missing required argument 'text'.");
        ensure_table();
        char tesc[4096];
        osr_json_escape(text, tesc, sizeof tesc);
        char params[4200];
        snprintf(params, sizeof params, "[\"%s\"]", tesc);
        return take(g_host->db_exec(
            "INSERT INTO memos(text, created) VALUES(?, strftime('%s','now'))", params));
    }

    if (strcmp(id, "memo_list") == 0) {
        if (!g_host->db_query) return fail("not_supported", "db unavailable");
        ensure_table();
        return take(g_host->db_query(
            "SELECT id, text, created FROM memos ORDER BY id DESC LIMIT 50", NULL));
    }

    if (strcmp(id, "memo_clear") == 0) {
        if (!g_host->db_exec) return fail("not_supported", "db unavailable");
        ensure_table();
        return take(g_host->db_exec("DELETE FROM memos", NULL));
    }

    if (strcmp(id, "run_background") == 0) {
        if (!g_host->dispatch) return fail("not_supported", "dispatch unavailable");
        char prompt[2048];
        if (!osr_json_get_string(payload ? payload : "", "prompt", prompt, sizeof prompt) || prompt[0] == '\0')
            return fail("invalid_args", "Missing required argument 'prompt'.");
        char pesc[4096];
        osr_json_escape(prompt, pesc, sizeof pesc);
        char req[4300];
        snprintf(req, sizeof req, "{\"prompt\":\"%s\",\"title\":\"Memo background task\"}", pesc);
        return take(g_host->dispatch(req));
    }

    return fail("tool_not_found", "unknown tool");
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
