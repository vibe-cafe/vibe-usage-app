# Releasing Vibe Usage

## Release-machine credentials

Multiple authorized Macs may hold the same signing identity and Sparkle key.
Adding a release Mac does not revoke or disable the original Mac; each machine
must independently pass the checks below. A historical report that credentials
exist only on one Mac is an inventory snapshot, not a one-device restriction.

Each Mac used for a production release must have all three of these items:

1. A valid `Developer ID Application: JIANZHONG ZHAO (8HGCD674ZS)` identity, including its private key.
2. A working `notarytool` Keychain profile named `VibeUsage-8HGCD674ZS` for team `8HGCD674ZS`,
   stored with `notarytool store-credentials`; it currently holds an App Store
   Connect API key of that team (`--key`/`--key-id`/`--issuer`).
3. The current Sparkle Ed25519 private key in the login Keychain.

Verify the Apple credentials with:

```bash
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile VibeUsage-8HGCD674ZS
```

Releases up to and including 0.7.4 used `Developer ID Application: Yin Ming
(D33463FWDZ)` and that team's `VibeUsage` profile; see "Signing identity
history" below.

## CLI dependency and release ordering

The app runs whatever `@vibe-cafe/vibe-usage@latest` resolves to, so a released
CLI must keep the contracts the app consumes (config JSON, sync output, and the
`quota` protocol with `schemaVersion` 1). Versions older than 0.11.0 have no
`quota` command at all — the app must report that as an actionable "update the
CLI" error instead of an empty card. Never reintroduce an exact-version pin:
pins rot silently and freeze users out of CLI fixes.

Before publishing the CLI, validate the actual local npm package:

```bash
node scripts/check-cli.mjs --from-local ../vibe-usage
node --test scripts/check-cli.test.mjs
```

Merge and publish that CLI version first (0.11.0 shipped the quota commands). Then run:

```bash
node scripts/check-cli.mjs
```

The default check downloads the current `latest` npm tarball and validates the
package's JSON config output, discovery, and all three quota adapters using
temporary directories without credentials. It ignores `VIBE_USAGE_CLI_PACKAGE`.
`build-app.sh` runs this check before creating a normal app bundle, so an
unpublished, missing, or incompatible CLI prevents packaging. `swift build`
alone only compiles the app and does not validate its runtime npm dependency.
If the planned version is taken before publication, update both CLI manifests
and `RuntimeDetector.defaultPackageSpecifier` to the reviewed version together.

Pre-publish Swift integration uses `VIBE_USAGE_CLI_PACKAGE` with the local
checkout and a temporary `VIBE_USAGE_CONFIG_DIR`; see `CLIBridgeTests`.
This verifies local compatibility and does not satisfy the production npm gate.

## Bundled Node

Ordinary builds ship the official Node.js named in `scripts/bundled-node.env`
at `Contents/Helpers/node` (approved 2026-11-14, 《Mac 自带 Node 方案》). Before
every release:

1. Check https://nodejs.org/dist/index.json for a newer `v24.*` patch. If there
   is one, copy the version and the two `node-v<version>-darwin-arm64.tar.xz` /
   `node-v<version>-darwin-x64.tar.xz` lines of its `SHASUMS256.txt` into
   `scripts/bundled-node.env` and commit that with the version bump.
   `scripts/fetch-node.sh` accepts a tarball only when its SHA256 equals both
   the published list and the pinned value.
2. `build-app.sh` re-signs the binary with `scripts/node.entitlements`
   (`allow-jit`, `allow-unsigned-executable-memory` — nothing else), refuses it
   if it carries `get-task-allow`, and runs the app's start-up probe, the
   shipped launcher and `check-cli.mjs` with the signed copy natively and, on
   Apple silicon, its Intel slice under Rosetta (Rosetta must be installed for
   `--notarize`).
3. After notarization, read `xcrun notarytool log <submission-id> --keychain-profile VibeUsage-8HGCD674ZS`
   and confirm it has no warnings about `Contents/Helpers/node`; check
   `codesign -d --entitlements - "dist/Vibe Usage.app/Contents/Helpers/node"`
   shows only the two entitlements, and `lipo -archs` on it says
   `x86_64 arm64`.

The CLI launcher `VibeUsage/Resources/cli-bootstrap.mjs` is a byte-for-byte
copy of `vibe-usage-windows` `src-tauri/resources/cli-bootstrap.mjs`. A release
build stops unless it equals `origin/main` of the `vibe-usage-windows` checkout
beside this repository (`scripts/check-cli-bootstrap.sh --sibling`; set
`VIBE_USAGE_WINDOWS_REPO` if it lives elsewhere). Change the launcher in the
Windows repository first.

Sparkle still receives a zip (`VibeUsage.zip`); only the DMG moved from UDZO
to ULMO compression, which macOS 10.15 and later open.

## External test build

An external test build uses the production API and the normal per-user config,
but includes the local, redacted quota diagnostic exporter and embeds an exact
CLI checkout. Both repositories must be clean so the package can record the app
commit plus the CLI commit and package version. Build it only with the explicit
flags:

```bash
./scripts/build-app.sh \
  --external-test \
  --cli-source ../vibe-usage \
  --universal \
  --notarize
```

Do not generate or publish an Appcast for an external test build. Ordinary
Release builds omit the test-build JSONL diagnostic log (`TestDiagnosticLog`)
and its export UI, the separate Keychain namespace, and the bundled CLI at
compile time. They do include the whitelisted 「复制诊断信息」 summary and the
local last-10 sync history approved on 2026-11-09 (see `AGENTS.md`). When release credentials are not
available, omit `--notarize` to create an ad-hoc signed
`dist/VibeUsage-Test.zip`; testers must use macOS Control-click → Open. The
signed/notarized path remains the preferred wider-distribution artifact.

## Adding another release Mac

Keep the original machine configured. Obtain the existing Developer ID
certificate **and its private key** from the authorized credential holder
(for example, a password-protected PKCS#12 export), import them into the new
Mac's Keychain, and configure a working `VibeUsage-8HGCD674ZS` notarization
profile there.
Then import and verify the existing Sparkle key as described below. A public
certificate alone cannot sign an app. No credential transfer or key rotation
is implied by a request to document these steps.

Changing to a different Apple Developer signing identity is a separate change:
update the build configuration and validate the installed-app upgrade path.
Sparkle's regular-app key rotation supports changing the Apple signing
certificate or the EdDSA key in an update, but not both at once. Merely adding
a release machine needs neither rotation nor a new signing identity.

### Signing identity history

- Up to and including 0.7.4: `Developer ID Application: Yin Ming (D33463FWDZ)`,
  notarized with that team's `VibeUsage` profile.
- From 0.7.5: `Developer ID Application: JIANZHONG ZHAO (8HGCD674ZS)`,
  notarized with `VibeUsage-8HGCD674ZS` (maintainer-approved 2026-11-11). The
  Sparkle key and `SUPublicEDKey` did not change, which is what lets installed
  0.5.4 (build 25) and later accept the differently signed update directly.
  The release gate for this switch is a local two-hop rehearsal before
  publishing: an installed 0.7.4 updates to the final notarized build through
  a local feed, and that build then updates once more to a local-only test
  build, proving that the newly signed app can still receive later updates.
  It also checks that an installed 0.5.3 pointed at the same local feed is
  offered 0.7.4, not 0.7.5.
- Installs of 0.5.3 (build 24) and earlier still embed the Sparkle key retired
  in 0.5.4, so for them a 0.7.5+ update changes both the key and the team and
  Sparkle would reject it. `scripts/generate-appcast.sh` passes
  `--minimum-update-version 25`, which stamps every new item with
  `sparkle:minimumUpdateVersion` 25; Sparkle hides such items from builds
  below 25, so those installs are offered 0.7.4 (build 40: old team, current
  key) first and reach the latest release from there. This only works while
  the 0.7.4 item stays in the feed, so seed `dist/appcast.xml` from the
  published feed before generating (see "Production release"). Do not remove
  the flag: `generate_appcast` only stamps the items it creates.
- Users who saved ZCode API keys in the app see a Keychain access prompt after
  the first launch of a build signed by a different team, because each
  Keychain item's access list trusts the old signature. The BigModel and Z.ai
  keys are separate items, so a user who saved both may be asked once for
  each. Choosing "Always Allow" ends the prompts for that item. Nothing else
  in the app depends on the signing team.
- The `8HGCD674ZS` certificate expires 2027-02-01 (issued under the G1
  intermediate). Replace it with a new certificate in the same team before the
  first release after that date and delete the expired one from Keychain; a
  same-team certificate needs no user-visible migration.

References: [Apple signing-identity export](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
and [Sparkle key transfer and rotation](https://sparkle-project.org/documentation/).

The Sparkle key was rotated for `v0.5.4`. Every later release must use the
private key matching the current `SUPublicEDKey` in `VibeUsage/Info.plist`.
An older release Mac may still contain the retired key, so do not generate an
appcast there until the current key has been imported and verified.

On a Mac that already has the current key, export it to a secure location:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  -x /secure/path/vibe-usage-sparkle-private-key
```

Transfer the file using an encrypted channel or encrypted removable storage.
The exported file is equivalent to a password: never commit it, attach it to an
issue, or leave an unencrypted copy in cloud storage.

On the destination Mac, pull the latest `main` branch, then import the key:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  -f /secure/path/vibe-usage-sparkle-private-key
```

If the import reports a conflict, first back up the destination Mac's old key,
then remove its existing **Private key for signing Sparkle updates** item from
Keychain Access and retry the import.

Verify that the imported key matches the repository:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' VibeUsage/Info.plist
```

The two public keys must be identical before running
`scripts/generate-appcast.sh`. If they differ, stop: publishing an appcast with
the wrong private key will break automatic updates.

After the import succeeds, delete the transfer copy or move it into a durable,
encrypted backup. Keep at least one recoverable backup so a lost release Mac
does not require another signing-key rotation.

## Production release

Once all credential checks pass, follow the release sequence documented in
`AGENTS.md`:

```bash
./scripts/check-version.sh
# scripts/bundled-node.env on the newest 24.x patch (see "Bundled Node")
./scripts/build-app.sh --universal --notarize
curl -fL -o dist/appcast.xml https://github.com/vibe-cafe/vibe-usage-app/releases/latest/download/appcast.xml
./scripts/generate-appcast.sh
```

The `curl` step seeds the currently published feed so older items, in
particular the 0.7.4 stepping-stone item, carry over into the new appcast.
`generate-appcast.sh` stops if that item is missing.

Publish `dist/VibeUsage.dmg`, `dist/VibeUsage.zip`, and `dist/appcast.xml`, then
verify that all three assets are present on the GitHub release.

**Appcast enclosure URLs must be pinned to `releases/download/<tag>/`, never
`releases/latest/download/`.** `SUFeedURL` in `Info.plist` fetching the feed
document itself via the `latest` alias is fine — that document is re-fetched
fresh every time. But each `<enclosure url>` inside it points at a specific,
already-signed ZIP; `generate_appcast` reuses and rewrites the existing
`appcast.xml` in place, so an older item's enclosure URL never gets refreshed.
If it was ever left pointing at `releases/latest/download/VibeUsage.zip`, the
next release ships, GitHub repoints `latest` at the new asset, and the old
item's EdDSA signature (computed over the old ZIP's bytes) no longer matches
what `latest` now serves — Sparkle then refuses the update with "The update is
improperly signed and could not be validated." A user hit exactly this on
2026-09-18 at 17:37, minutes after 0.6.2 shipped. `generate-appcast.sh` now
passes `--download-url-prefix .../releases/download/v<version>/` and
post-processes `appcast.xml` to rewrite any remaining legacy `latest` item
URLs, so this should no longer recur — but if you ever hand-edit
`appcast.xml` or upload assets with `gh release upload` under a **tag that
isn't `v<version>`**, the per-tag URL 404s. Every existing release tag follows
`v<CFBundleShortVersionString>` (`v0.6.2`, `v0.6.1`, `v0.5.10`, ...); keep it
that way, or set `APPCAST_TAG` when invoking `generate-appcast.sh` if a
release is ever cut under a different tag.
