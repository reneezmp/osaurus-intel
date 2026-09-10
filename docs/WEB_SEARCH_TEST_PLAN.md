# Intel Web Search Test Plan

## Automated coverage

- Provider configuration defaults, JSON persistence, custom definitions, and
  removal cleanup.
- API provider request mapping for Tavily, Brave, Serper, Google CSE, Kagi,
  You.com, Exa, and Parallel.
- Built-in Brave, Bing, and DuckDuckGo response parsing, challenge detection,
  fallback order, last-resort behavior, and URL de-duplication.
- Provider cascade behavior for disabled, unconfigured, failed, pinned, and
  unsupported-category routes.
- Search-and-extract URL safety, private/metadata address rejection, response
  size limits, challenge pages, boilerplate pages, canonical URLs, and output
  truncation.
- Stable `web_search` schema, first-party Intel tool registration, per-agent
  opt-in filtering, and backward-compatible settings persistence.
- Legacy `search-intel` plugin retirement so it cannot replace the native tool.

## Rosy acceptance — pending

Run these on the Intel Mac before changing Web Search from **Partial** to
**Working and tested** in `FEATURE_PARITY.md`.

1. Open Settings → Web Search and confirm the page fits at Rosy's normal window
   size without clipped controls or overlapping text.
2. Confirm Web Search starts off for an existing agent and a newly created
   agent. Enable it, relaunch, and confirm the choice persists.
3. With Web Search off, verify the model does not receive or call
   `web_search`/`search_and_extract`. With it on, verify a real tool call appears
   and its result is returned to the model.
4. Run a built-in web search with no API key. Confirm useful results or a clear,
   redacted failure; no paid service may run.
5. Add one API provider credential, relaunch, run Test Search, disable and
   re-enable the provider, then delete it. Confirm the secret never appears in
   logs, diagnostics, exported configuration, or error text.
6. Change provider order and category preference, relaunch, and verify the
   selected order is used. Exercise web, news, and images where supported.
7. Add a custom REST provider, test it, relaunch, and remove it. Confirm bundled
   provider identifiers cannot be shadowed.
8. Exercise `search_and_extract` with a normal article, a redirect, a large
   page, and a localhost/private-network URL. Confirm normal extraction works
   and unsafe targets are rejected before fetch.
9. Confirm an installed legacy `search-intel` plugin is ignored and does not
   duplicate or override the native tool.
10. Test cancellation and offline/provider-failure behavior. The chat must stay
    responsive and present a useful retry path.

## Dependency boundary

Osaurus Premium Search is intentionally absent. It depends on the revamped
Credits wallet and Router service, including balance state, explicit paid
consent, billing errors, diagnostics, and fallback policy. Add that integration
as part of the Credits/Router roadmap and link it into the existing Search page
only after the complete service path is testable.
