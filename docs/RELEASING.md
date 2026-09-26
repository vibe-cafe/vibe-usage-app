# Releasing Vibe Usage

## Release-machine credentials

Each Mac used for a production release must have all three of these items:

1. A valid `Developer ID Application: Yin Ming (D33463FWDZ)` identity, including its private key.
2. A working `notarytool` Keychain profile named `VibeUsage`.
3. The current Sparkle Ed25519 private key in the login Keychain.

Verify the Apple credentials with:

```bash
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile VibeUsage
```

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
Release builds omit the diagnostic implementation, UI, separate Keychain
namespace, and bundled CLI at compile time. When release credentials are not
available, omit `--notarize` to create an ad-hoc signed
`dist/VibeUsage-Test.zip`; testers must use macOS Control-click → Open. The
signed/notarized path remains the preferred wider-distribution artifact.

## Moving releases to another Mac

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
./scripts/build-app.sh --notarize
./scripts/generate-appcast.sh
```

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
