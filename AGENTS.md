# Sprintwake Projects

Native macOS 14+ GitHub Projects client. Swift 6, SwiftUI, Foundation, Security;
Sparkle 2.10.1 is the only third-party runtime dependency, for signed updates.
The Swift package and Package.resolved are the source of truth.

## Project records

- Read the current snapshot at the top of `STATUS.md` and the ordered next work
  in `PLAN.md` when continuing. Dated historical entries retain superseded
  blockers/test counts; do not treat them as the current task list.
- Keep `PLAN.md` aligned with completed work and remaining release prerequisites.
  `CONTEXT.md` records durable architecture/decisions; README links to the current
  status and plan. Do not claim public publication from local/demo verification.
- Record user-visible changes in `CHANGELOG.md` under the release version/date;
  use that entry when writing GitHub release notes.

## Commands

- `swift build` — debug build.
- `./scripts/test.sh` — isolated network/authentication/state tests. No GitHub writes.
  Calls `swift test` and handles the Swift 6.4 CLT TestingMacros discovery issue.
- `swift build -c release` — optimized build.
- `./scripts/build-app.sh` — build and ad-hoc sign `dist/Sprintwake Projects.app`.
- `./scripts/build-app.sh --debug` — package the debug build.
- `./scripts/test-release.sh` — isolated release configuration/appcast validation.
- `./scripts/release.sh` — prepare an ad hoc-signed community release ZIP,
  Ed25519-signed appcast/archive and checksum; requires a clean committed tree
  and the update key in Keychain. No Apple membership is required.
  Creates/verifies a local tag, prints the GitHub publish command without running it.
- `./scripts/release.sh --notarize` — additionally Developer ID-sign and notarize;
  requires the Apple identity and a notarization profile. Fail closed on errors.
- `open "dist/Sprintwake Projects.app"` — start the packaged app.
- `open "dist/Sprintwake Projects.app" --args --demo` — start an isolated local demo.
- `FJORD_KEYCHAIN_TEST=1 ./scripts/test.sh --filter KeychainTests` — optional round-trip
  using an isolated temporary Keychain service, with cleanup.

CI runs `./scripts/test.sh`, `./scripts/test-release.sh` and
`./scripts/build-app.sh` on macOS, then uploads the packaged ZIP.
No separate lint or formatter is configured.

Swift 6.3 compatibility: use an explicit closure for actor-isolated SwiftUI
Binding setters (for example `{ model.setSource($0) }`). A direct bound method
reference can crash that compiler's IR generation; local Swift 6.4 masks it.

## Boundaries

- `Sources/FjordCore`: models, GitHub transport, Device Flow, Keychain/session,
  application state. Keep API calls injectable and test without real credentials.
- `Sources/Fjord`: SwiftUI views and macOS integrations.
- Tokens and device codes must never appear in logs, defaults, source, or fixtures.
- The public OAuth Client ID may be stored in defaults or bundled in Info.plist.
  `Configuration/GitHub.json` is the public build default;
  `FJORD_GITHUB_CLIENT_ID` overrides it, including empty to omit the bundled ID.
- `Configuration/Slack.json` is the optional public Slack Client ID default;
  `SPRINTWAKE_SLACK_CLIENT_ID` overrides it, including empty to omit the bundled ID.
  Slack uses a native PKCE public client and never embeds a Client Secret. See
  `Documentation/Slack-setup.md` and `Configuration/SlackManifest.json`.
- Never embed a Client Secret. Scope changes happen through user authorization.
- Confirm mutations at GitHub before changing visible application data.
- Do not replace live single-select option collections: GitHub has no conditional
  append, so concurrent edits can remove options. Open GitHub's board for column
  creation. Only the isolated demo adds/deletes columns in memory.
- Chat is backed by self-assigned project drafts. Treat draft creation followed
  by a failed status update as a partial success, never a reason to recreate it.
  Insert the mutation-confirmed message directly; do not wait for a full project
  snapshot to show a successful send. In-flight Slack history must not erase a
  newly confirmed send.
- Shared-project discovery queries actual project access after finding candidate
  owners through organization membership, repository collaboration and opened links.
  Repository membership alone is not project access; unrelated public read-only
  boards are not shares. Keep the catalog and seen/canonical-link preferences
  account-scoped; preserve board selection and old data on transient read errors.
  Rotate bounded owner scans, honor GitHub rate-limit reset/retry times, and cancel
  discovery on logout/reauthorization so no further owner reads use the old token.
- GitHub has no documented global shared-project or ProjectV2 invitation inbox.
  Unknown standalone owners and personal public read-only boards need a project
  link once. Do not claim universal discovery or present local actions as GitHub
  invitation acceptance/declining. No separate invitation service is implemented.
- Preserve sessions on transient network/permission errors. Invalidate on 401 only.
- Slack credentials are user tokens stored in Keychain per GitHub account. Keep
  Slack project/channel bindings local, respect uncertain delivery without retry,
  and never send real test messages; the isolated demo has no Keychain/network.
- Guard async results against sign-out and project/owner changes.
- Update README, CONTEXT.md, STATUS.md when durable behavior changes.

- Real issue creation, project linking and column placement are distinct writes.
  Preserve partial success and the created issue URL; never retry creation after
  a confirmed create merely because the later steps failed.
- Issue/PR assignments use atomic add/remove. Draft assignments must read current
  IDs and fail closed if inaccessible; GitHub requires full-array replacement.
  Surface the remaining same-draft concurrency limitation in UI and docs.
  The mutation's `Assignable` response has no `id` field; select it through a
  `... on Node { id }` fragment.
- Project deletion requires an explicit in-app confirmation with the project name.
  Exercise destructive workflows only in the isolated demo, never real projects.
- A separate test bundle can set `FjordDemoMode=true` in Info.plist and use its own
  bundle identifier; it starts local data without reading the real session.

- Sprintwake Projects is the display name. Keep the established `no.oddmund.Fjord` bundle ID,
  Keychain service, preferences and Swift target/module names for compatibility.
  The external OAuth registration is still named Fjord Projects.
- Redacted item content is a GitHub permission decision. Never fabricate titles
  or infer repository access from project access. Reauthorization must keep the
  working session until a verified same-account replacement succeeds.
- Editable logo sources are in `Branding/`; `BrandMark.swift` and
  `scripts/make-icon.swift` use the same route geometry. Regenerate PNG assets with
  `swift scripts/make-icon.swift Branding/Sprintwake-icon.png Branding/Sprintwake-mark.png`.

- Shared workspace colors and card surfaces live in `Sources/Fjord/WorkspaceStyle.swift`.
  Preserve light/dark appearance, increased-contrast borders and native keyboard controls.
  Verify visual changes in an isolated demo at both default and minimum window sizes.

- English is the development language. All application-owned UI and error/notice
  text uses `L10n.ui` or `L10n.core` with stable English keys and matching en/nb
  `.strings` tables. Format arguments are passed separately; never interpolate a
  localization key. User and GitHub content stays unchanged.
- Language preference `appLanguage` supports system/en/nb. Language changes must
  preserve the session and project selection. Include the SwiftPM resource bundle
  in packaged apps; verify localization outside the source/build directories.
- Fresh installations default to English, independent of the Mac's language.
  Preserve saved language choices, including an explicit system preference.
- Public README screenshots use fictional English demo data only. Capture a
  separately identified `FjordDemoMode=true` bundle, never the real session.
  Screenshot provenance is in `Documentation/Screenshots/README.md`.

- Update versions/build numbers, release repository and public Ed25519 key live in
  `Configuration/Release.json`. Increment build for every public update. Never
  commit/export the production private signing key; it stays in Keychain account
  `Sprintwake Projects Updates`. A fork must supply its own key and feed.
- Local builds and demos do not contact update servers. Production releases enable
  Sparkle with HTTPS, signed feeds and archives, verification before extraction,
  explicit install/relaunch and no profile telemetry. Preserve the complete Sparkle
  license and framework symlinks; sign nested helpers before enclosing bundles.
- Community releases use ad hoc app signing plus Ed25519-signed feeds/archives,
  independently of Apple membership. Only explicit `--notarize` enables Developer
  ID checks, hardened runtime/timestamps and Apple notarization. Preserve the
  same feed/key protections in both paths. Never disable or bypass Gatekeeper;
  document that community builds may require the user's first-install approval.
- `SPRINTWAKE_APP_PATH` overrides the package output. Never overwrite a running app.
  `SPRINTWAKE_UPDATE_TESTING=1` produces a separate demo/test bundle and permits only
  loopback HTTP feed overrides. Production releases reject all test overrides.
- Delay an approved update restart while writes/authorization or unfinished edits
  remain; discarding edits requires an explicit user choice. Test replacement only
  with isolated demo bundles, never the real installed app or real credentials.
