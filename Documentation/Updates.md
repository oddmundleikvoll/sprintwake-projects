# Sprintwake Projects updates

Sparkle 2.10.1 checks a signed appcast and installs signed archives from GitHub
Release assets. Official releases check automatically; downloading, installing
and restarting require a user action. A download button appears when an update
is available. Active writes/authorization delay restart. Unfinished editors and
unsent messages prompt the user to keep editing or explicitly discard them.
Automatic installation and system-profile telemetry are disabled.

## Initial setup

The public repository is `oddmundleikvoll/sprintwake-projects`. The latest community
release is `v0.2.1` (build 3); the assignment correction is recorded
in [CHANGELOG.md](../CHANGELOG.md). The build scripts prepare local artifacts; publishing
is a separate manual step. Commit and push reviewed source before preparing
later releases, and increase the build number for each public update.
The [project plan](../PLAN.md) records publication and remaining fresh-install,
public-update and optional Slack distribution verification;
[STATUS.md](../STATUS.md) distinguishes local evidence from public release testing.

`Configuration/Release.json` contains the version, monotonically increasing
build number, repository and public Ed25519 update key. The owner's private key
was generated in macOS Keychain under **Sprintwake Projects Updates**; it has
not been exported. Keep that key and its secure backup under the owner's control.
A fork must use its own repository and signing key.

Fetch the pinned framework and tools with `swift package resolve`. Sparkle's
`bin` directory is `.build/artifacts/sparkle/Sparkle/bin`. For a new fork, run:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account 'Sprintwake Projects Updates'
```

Copy only the printed public key into `sparklePublicKey`. Never commit private
keys, certificate exports, Apple credentials or notarization secrets.

The default community release uses ad hoc app signing and Ed25519-signed
Sparkle updates, without a paid Apple Developer membership. This uses the same
separation of update signing and Apple signing as Sprintwake Studios. Sparkle
verifies the feed and downloaded archive using the bundled public key.

Community builds are not notarized by Apple. macOS may display an unidentified
developer warning or require manual approval on first installation. Users must
decide whether to trust the initial download. The release scripts do not disable
Gatekeeper or remove quarantine attributes. Update signatures authenticate later
updates from the same key; they do not provide Apple's developer identity or
malware assessment. Ad hoc rebuilds may also prompt again for Keychain access.

## Prepare a release

1. Update `version` and increment `build` in `Configuration/Release.json`, and
   record the user-visible changes under that version/date in `CHANGELOG.md`.
2. Commit the intended changes. The release script requires a clean committed tree.
3. Prepare a community release:

```sh
./scripts/release.sh
```

The script builds an ad hoc-signed app with public update checks enabled, includes
the project's MIT License and Sparkle's license in its resources, and creates
a ZIP preserving framework symlinks, and uses Sparkle tools to sign the archive
and appcast. It verifies both signatures against the configured key, version/build,
asset URL and archive length. Output is in `dist/release/<version>`.

### Optional Apple notarization

For Developer ID signing and notarization, obtain Apple Developer Program
membership, install a **Developer ID Application** certificate, and set up a
notarization profile interactively with `xcrun notarytool store-credentials`.
Keep its secrets in Keychain. Then explicitly request this path:

```sh
FJORD_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SPRINTWAKE_NOTARY_PROFILE='Sprintwake Notary' \
./scripts/release.sh --notarize
```

This path resolves a valid installed Developer ID identity, signs Sparkle's nested
helpers before their enclosing bundles, and signs the app with hardened runtime
and secure timestamps. It notarizes/staples the app before creating the final
ZIP, then applies the same Sparkle signing and verification as community releases.
Failure stops preparation; it never falls back to an unnotarized release.

### Publish the prepared release

The script pins a local annotated tag to the clean commit used for the build and
prints a shell-escaped **git push followed by gh release create** command. Review
then run that command to publish. Both the ZIP and `appcast.xml` must be assets of
the same non-draft, non-prerelease release. The client fetches:

```
https://github.com/oddmundleikvoll/sprintwake-projects/releases/latest/download/appcast.xml
```

Use the matching `CHANGELOG.md` entry for the release notes. For multiline notes,
write the final text to a file and pass `--notes-file` to `gh release create`.

Releases must increase the build number. Keep the public key/feed stable for
installed clients. Builds currently target the host Mac architecture; Sparkle's
generated hardware requirement prevents incompatible architecture updates.
Both distribution paths require signed feeds and archives and verify them before
extraction. Keep the same Sparkle key/feed when adding Apple notarization later.

## Local development and verification

Ordinary `./scripts/build-app.sh` builds are ad hoc signed with public updater
networking disabled. Existing local installations need the first official build
before they can receive future public updates. Set `SPRINTWAKE_APP_PATH` to an
alternate output; packaging refuses to overwrite a running app.

`./scripts/test.sh` covers configuration, demo isolation and relaunch deferral.
`./scripts/test-release.sh` checks release metadata, unsafe feeds, identity
resolution and appcast validation. `scripts/verify-update.swift` verifies archive
Ed25519 signatures with the public key and rejects changed archives.

Only `SPRINTWAKE_UPDATE_TESTING=1` permits loopback HTTP feeds and the
`SPRINTWAKE_UPDATE_FEED_URL` / `SPRINTWAKE_UPDATE_PUBLIC_KEY` overrides. This mode
builds a separate `no.oddmund.Sprintwake.UpdateTest.Local` app with `FjordDemoMode`
enabled and no Slack callback registration. It never restores real GitHub/Slack
credentials. Use disposable test keys and a local server, with an older and a
newer copy having the same test bundle ID. The production release script rejects
all testing overrides. A normal `--demo` never contacts update servers.

Contracts: [Sparkle setup](https://sparkle-project.org/documentation/),
[update publication](https://sparkle-project.org/documentation/publishing/),
[gentle update reminders](https://sparkle-project.org/documentation/gentle-reminders/).
