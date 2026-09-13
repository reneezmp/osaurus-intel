# Intel Credits, Router, and Premium Web Search Plan

This plan ports the modern Credits/Router experience selectively to the Intel
fork. It does not treat an upstream commit review as proof that its product
behavior exists here. A gate leaves **Partial** only after compiled source,
runtime wiring, persistence, focused Intel tests, an x86_64 build, and Rosy
Ventura acceptance all agree.

## Product contract

Router availability, Premium Search consent, and wallet auto-pay are three
separate settings. Router on never implies consent to paid search. Premium
Search defaults off until the user explicitly enables it. Included search
credits run before wallet funds; wallet fallback requires its own explicit
setting.

Search and page extraction use one idempotency key per logical operation.
Failures, empty/replayed responses, insufficient funds, disabled paid web,
rate limits, unavailable endpoints, and provider errors fall back to the
existing native provider cascade. A fallback must not invent a fresh key and
retry a possibly billed operation. Images and video stay on the existing path.

Diagnostics and model-facing tool output may report safe source/fallback
metadata. They never include raw Router bodies, wallet balance, cost, request
IDs, queries, URLs, page content, prompts, or responses. Hosted extraction must
preserve the existing private-address protections.

## Gates

### C1 — Wallet safety and Router master switch

- Persist an explicit Router opt-out; absent preference remains enabled for
  existing users.
- Turning Router off removes its managed models, clears cached account state,
  and suppresses balance, usage, catalog, inference, and future hosted-search
  requests.
- Disabling asks for confirmation; enabling may reconnect immediately.
- Parse top-up amounts without integer overflow.
- Add focused preference and amount-boundary tests.

**Implemented on M4, pending Rosy:** the Intel manager now owns the persisted
switch, removes the managed provider and cached account state when disabled,
and reconnects when enabled. Credits renders an honest off state and confirms
disable. The amount parser rejects non-finite and overflowing values. Two
focused tests pass and the signed x86_64 app builds with macOS 13.0 minimum.

### C2 — Revamped Credits

- Display balances and activity in credits.
- Add bounded, idempotent code redemption and typed/redacted failures.
- Add the account usage center. Restore Insights links only after Intel
  request/turn correlation is proven.
- Keep the local diagnostic ledger metadata-only.

**Implemented on M4, pending Rosy:** balances, model prices, usage, and wallet
activity now use the Router's credit unit while Checkout still states the real
dollar charge. The Credits page has a bounded redeem-code flow with typed,
redacted failures and an account usage center built from the existing signed
`/usage` and `/credits/transactions` contracts. Redemption is deliberately
Credits-only: upstream onboarding/welcome-credit coordination is a separate
dependency and remains in the backlog. Insights deep links remain absent until
Intel request/turn correlation is proven. Focused validation passes 8 tests in
4 suites. The Rosy script produces an x86_64 app with macOS 13.0 minimum and
applies the configured identity; strict trust verification on the M4 reports
`CSSMERR_TP_NOT_TRUSTED`, so Rosy launch remains the signing acceptance gate.

### C3 — Premium Web Search

- Add signed Router contracts for web settings, web usage, `/v1/search`, and
  `/v1/contents` with typed 402/403/404/409/429/5xx handling and backoff.
- Add a persisted Premium setting that defaults off and a separate wallet
  auto-pay setting.
- Route Settings test search and agent tools through the same hosted-first
  coordinator, preserving native fallback and agent-level Web Search gating.
- Project billing status into Credits without leaking financial or request
  details into model context.

### C4 — Rosy promotion

- Run focused suites and the full serialized storage-safe suite.
- Produce a signed x86_64 app with macOS 13.0 minimum.
- Complete the final checklist on Rosy Ventura with a disposable funded account
  or Router test environment.
- Promote the feature only from observed Rosy evidence.

## External dependencies and backlog links

The hosted Router must provide the four web endpoints and stable error codes.
If any contract is absent, keep its UI explanatory and record the server work
in the backlog; do not ship a working-looking control. Browser Checkout remains
an external handoff. Insights deep links remain blocked until Intel correlation
is measured. Onboarding-triggered welcome-credit redemption remains separate
from the Credits page and must be linked only after that coordinator exists on
Intel. Premium image/video search remains outside C3.

## Maintenance rule

Whenever implementation, testing, Rosy, or an upstream audit reveals an
important product boundary, dependency, failure mode, or portability trap,
update this plan, `FEATURE_PARITY.md`, `UPSTREAM_SYNC.md`, and the final Rosy
checklist in the same change. The manuals are part of the feature contract.
