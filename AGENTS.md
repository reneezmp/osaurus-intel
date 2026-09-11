# Repository Working Rules

## Keep the manuals alive

Before upstream-sync, Intel compatibility, storage, release, or Rosy QA work,
read the relevant files under `docs/`, especially:

- `docs/UPSTREAM_SYNC.md`
- `docs/FEATURE_PARITY.md`
- `docs/TEST_STORAGE_SAFETY.md`
- the feature-specific test plan or Rosy retest checklist

When work reveals an important fact, update the relevant manual in the same
change. This includes a failed assumption, compatibility constraint, incident,
recovery procedure, newly discovered dependency, changed validation command,
or manual QA result. Do not leave durable knowledge only in a chat, commit
message, temporary note, or test log.

If no existing manual is suitable, create a focused file under `docs/` and link
it from `docs/UPSTREAM_SYNC.md` or the closest standing plan. Work is not
complete until another session can find the discovery before repeating the
same analysis or risk.

