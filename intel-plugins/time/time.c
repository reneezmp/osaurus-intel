// time.c — native x86_64 Osaurus plugin: current date/time.
//
// Exposes one tool, `get_current_time`, that takes no arguments and returns
// the current local + UTC time (ISO-8601), the system timezone, and the Unix
// epoch. No host callbacks needed — pure libc.

#include "osaurus_plugin.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

static const osr_host_api *g_host = NULL;

static void p_free_string(const char *s) { if (s) free((void *)s); }
static osr_plugin_ctx_t p_init(void) { static int t = 1; return (osr_plugin_ctx_t)&t; }
static void p_destroy(osr_plugin_ctx_t c) { (void)c; }

static const char *p_get_manifest(osr_plugin_ctx_t c) {
    (void)c;
    static const char *m =
        "{\"plugin_id\":\"time-intel\",\"name\":\"Time\",\"version\":\"1.0.0\","
        "\"description\":\"Current date and time.\","
        "\"capabilities\":{\"tools\":[{"
        "\"id\":\"get_current_time\","
        "\"description\":\"Returns the current date and time: local and UTC in ISO-8601, "
        "the system timezone, and the Unix epoch. Takes no arguments.\","
        "\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}"
        "}]}}";
    return strdup(m);
}

static const char *p_invoke(osr_plugin_ctx_t c, const char *type, const char *id, const char *payload) {
    (void)c; (void)type; (void)id; (void)payload;

    time_t now = time(NULL);
    struct tm lt, ut;
    localtime_r(&now, &lt);
    gmtime_r(&now, &ut);

    char local[64], utc[64], tz[64];
    strftime(local, sizeof local, "%Y-%m-%dT%H:%M:%S%z", &lt);
    strftime(utc, sizeof utc, "%Y-%m-%dT%H:%M:%SZ", &ut);
    strftime(tz, sizeof tz, "%Z", &lt);

    char buf[512];
    snprintf(buf, sizeof buf,
             "{\"ok\":true,\"local\":\"%s\",\"utc\":\"%s\",\"timezone\":\"%s\",\"epoch\":%ld}",
             local, utc, tz, (long)now);
    return strdup(buf);
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
