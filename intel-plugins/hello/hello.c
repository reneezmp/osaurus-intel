// hello.c — a tiny x86_64 Osaurus plugin proving native execution on the
// Intel fork (M9 Phase D).
//
// Exports the v2 entry point, implements the required plugin API
// (free_string / init / destroy / get_manifest / invoke), and on invoke
// returns a JSON greeting. It also exercises the host's log callback so the
// slim Intel host API gets a real round-trip.
//
// Build:  ./build.sh   (clang -arch x86_64 -dynamiclib)
// Install: copy plugin.dylib + manifest.json into
//          ~/.osaurus-intel/Tools/hello-intel/

#include "osaurus_plugin.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static const osr_host_api *g_host = NULL;

// ── Required plugin API ──

static void plugin_free_string(const char *s) {
    if (s) free((void *)s);
}

static osr_plugin_ctx_t plugin_init(void) {
    // A non-NULL opaque context. We hold no per-instance state, so a stable
    // sentinel address is enough — the host only needs it to be non-NULL.
    static int ctx_token = 0xA1;
    return (osr_plugin_ctx_t)&ctx_token;
}

static void plugin_destroy(osr_plugin_ctx_t ctx) {
    (void)ctx;
}

static const char *plugin_get_manifest(osr_plugin_ctx_t ctx) {
    (void)ctx;
    static const char *manifest =
        "{"
        "\"plugin_id\":\"hello-intel\","
        "\"name\":\"Hello Intel\","
        "\"version\":\"1.0.0\","
        "\"description\":\"A tiny native x86_64 plugin proving the Intel fork can dlopen + invoke plugins.\","
        "\"capabilities\":{\"tools\":[{\"id\":\"hello\",\"description\":\"Returns a friendly greeting.\"}]}"
        "}";
    return strdup(manifest);
}

static const char *plugin_invoke(osr_plugin_ctx_t ctx,
                                 const char *type,
                                 const char *id,
                                 const char *payload) {
    (void)ctx;
    (void)type;

    // Round-trip the slim host log callback so we exercise host → plugin
    // wiring, not just plugin → host.
    if (g_host && g_host->log) {
        g_host->log(2, "hello-intel: invoke received");
    }

    size_t payload_bytes = payload ? strlen(payload) : 0;

    char buf[512];
    snprintf(buf, sizeof(buf),
             "{\"ok\":true,"
             "\"tool\":\"%s\","
             "\"message\":\"Hello from a native x86_64 plugin running on the Osaurus Intel fork!\","
             "\"payload_bytes\":%zu}",
             id ? id : "",
             payload_bytes);
    return strdup(buf);
}

// ── Entry point ──

static osr_plugin_api g_api;

const osr_plugin_api *osaurus_plugin_entry_v2(const osr_host_api *host) {
    g_host = host;

    g_api.free_string = plugin_free_string;
    g_api.init = plugin_init;
    g_api.destroy = plugin_destroy;
    g_api.get_manifest = plugin_get_manifest;
    g_api.invoke = plugin_invoke;
    g_api.version = OSR_ABI_VERSION_2;
    g_api.handle_route = NULL;
    g_api.on_config_changed = NULL;
    g_api.on_task_event = NULL;

    return &g_api;
}
