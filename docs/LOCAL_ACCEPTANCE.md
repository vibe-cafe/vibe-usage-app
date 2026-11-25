# Local acceptance checks

Run the ordinary suite first:

```sh
swift test --disable-sandbox
```

`LocalAcceptanceTests` skips real-account and Keychain operations by default.
Select these checks only on a machine whose account owner has authorized the
requests. Never paste credentials into a command, test fixture, or test report.

```sh
VIBE_USAGE_LIVE_CODEX=1 swift test --disable-sandbox \
  --filter LocalAcceptanceTests/testLiveCodexQuota

VIBE_USAGE_LIVE_KIMI_GROK=1 VIBE_USAGE_CLI_PACKAGE=/absolute/path/to/vibe-usage \
  swift test --disable-sandbox \
  --filter LocalAcceptanceTests/testLiveKimiAndGrokThroughMacBridge

VIBE_USAGE_LIVE_KEYCHAIN=1 swift test --disable-sandbox \
  --filter LocalAcceptanceTests/testIsolatedKeychainCreateUpdateRegionalSeparationAndDelete

VIBE_USAGE_LIVE_PROBE=1 swift test --disable-sandbox \
  --filter ClaudeUsageProbeLiveTests
```

Codex and Kimi use the existing official login. Grok starts the official
`grok` CLI, which asks xAI once with its own existing login for the current
billing period (no session, no prompt); `source: live` means that request was
answered, while `source: local` is the fallback to the official local usage
log, whose last event may be older. The Keychain check uses dummy strings in a
random Debug-only service namespace, checks create/update/regional separation/
delete, and attempts cleanup on early failure. It never uses production keys.
An agent sandbox can prevent Security.framework access even with SwiftPM's
sandbox disabled; run this specific check in a normal local test process.

Claude's positive live check requires a logged-in account with applicable
subscription limits. `limitsNotApplicable` or a missing login does not count as
a positive quota result. ZCode positive acceptance additionally requires an
active BigModel or Z.ai Coding Plan key, entered by its owner in the external
test app. Verify the intended region, refresh, restart persistence, and removal.

For GUI acceptance, build the exact external test bundle as described in
[RELEASING.md](RELEASING.md). Record its app/CLI commits and architectures.
Exercise selection of zero/one/two products, replacement order, restart,
missing-login and retry states, stale-data labels, real sync, time ranges and
custom dates, each filter and clear, chart modes, units, and diagnostic export.
Use a separate empty `VIBE_USAGE_CONFIG_DIR` to verify quotas before Vibe Usage
linking. Preserve and restore the external app's preferences; do not reset the
shared account config merely to exercise onboarding.

Record positive, failed, skipped, and unavailable cases separately. A successful
local tarball check and an ad-hoc universal build do not replace the published
npm package gate, Intel execution, other supported macOS versions, signed
installation/update tests, or long-duration sleep/network/quota-rollover tests.
