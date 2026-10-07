# Router announcements on Intel (upstream #2982)

Upstream added a Router-served announcements feed on 2026-10-02
(`GET /announcements`): launches, events and heads-ups written by the
upstream Osaurus team for upstream Osaurus on Apple Silicon. Renée's
decision (2026-10-07): Intel shows them, **clearly marked as upstream's and
not ours, with the necessary warnings**.

## What Intel does

- Upstream's `AnnouncementsService`, client call
  (`OsaurusRouterAPIClient.announcements`), data types and
  `AnnouncementDialogContent`, with upstream's triggers: ~2 s after launch
  and on foreground activation (at most every 30 minutes, 60 s floor, 429
  backoff), and only while the Router is turned on.
- Upstream's "don't interrupt" deferrals that exist on Intel: onboarding,
  AppKit modals and sheets, another themed alert, the layout tour, a
  streaming chat, an active background task. Each slug shows once.

## Intel differences

- **Banner:** every dialog starts with "From the upstream Osaurus project,
  not Osaurus Intel" and a warning that features, models and offers it
  mentions may need an Apple Silicon Mac or a newer macOS and may not exist
  in Osaurus Intel, and that links open upstream's pages
  (`UpstreamAnnouncementNotice`).
- **Opt-out:** "Don't show upstream announcements" turns the feed off for
  good (`ai.osaurus.intel.upstreamAnnouncements.optedOut`; no fetch, no
  dialog). There is no Settings switch yet; deleting that defaults key turns
  it back on.
- **Links:** only `https` CTAs are offered. `osaurus://` deep links target
  upstream app screens that may not exist here, so they are dropped
  (`AnnouncementsService.intelCTAs`).
- **No `app_version`:** Intel's 1.x numbers are not upstream versions and
  would read as a future upstream build to the router's version bounds.
  Without it, the router applies no version filter.
- No telemetry events (Intel omits upstream's `FeatureTelemetry`), no DEBUG
  dock item, no paired-phone or Computer Use deferrals (Intel has neither).
- Upstream also removed its hard-coded Product Hunt campaign in this
  commit; Intel never had it.

## Files

`Services/Router/AnnouncementsService.swift`,
`Views/Common/AnnouncementDialogContent.swift`,
`OsaurusRouterTypes.swift` (announcement types),
`AppDelegate.swift` (`startUpstreamAnnouncements`,
`presentAnnouncementIfEligible`). Tests: upstream
`AnnouncementsServiceTests`, Intel `IntelUpstreamAnnouncementsTests`.
