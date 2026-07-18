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
