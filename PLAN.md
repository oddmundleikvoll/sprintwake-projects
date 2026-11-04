# Sprintwake Projects plan

Updated 2026-11-04. [STATUS.md](STATUS.md) contains the current snapshot and dated
verification history. [CONTEXT.md](CONTEXT.md) records architecture and decisions.
This plan tracks the work remaining before the first public release.

## Completed

- [x] Refresh the workspace, board cards, sign-in and conversation surfaces with
  a shared adaptive indigo palette and clearer visual hierarchy.

- [x] Native macOS GitHub Projects client: authentication/session restoration,
  board/list, project and task management, assignees and draft conversations.
- [x] Sprintwake Projects name, S logo, app icon and compatible internal identity.
- [x] English and Norwegian Bokmål, with a persistent language choice.
- [x] Diagnose inaccessible issue/PR content and add same-account repository
  reauthorization. All 12 items were visible in the authorized live project.
- [x] Optional Slack channel integration with PKCE, Keychain storage, history,
  plain-text sending, local channel bindings and an isolated demo.
- [x] Restore the real GitHub and Slack sessions and selected project/channel
  after restart. Real message/task writes were not used for implementation QA.
- [x] Sparkle download indicator, settings/menu, signed feed/archive checks and
  installation that protects active writes and unfinished edits.
- [x] Community release preparation without paid Apple membership. Developer ID
  and notarization remain optional through `./scripts/release.sh --notarize`.
- [x] Latest verification: 121 tests across 14 suites, release configuration and
  signature tests, optimized packaging, isolated native update/relaunch and
  rejection of changed archives. See STATUS.md for the exact scope and limits.
- [x] Retire the old Sporverk app copy by moving it to Trash.
- [x] Remove New task from the top toolbar; retain task creation through column plus buttons and ⌘N.
- [x] Display confirmed GitHub conversation sends immediately, and protect Slack
  sends against older in-flight history responses.
- [x] Apply those fixes to the standard app, verify its real-session restart,
  and remove the separate Preview app at the user's request.
- [x] Automatically discover accessible shared/team boards through GitHub
  connections, show owner/New markers, preserve opened links/selection per account,
  and refresh without changing the current board.

- [x] English on first launch, preserving saved English/Norwegian/system choices.
- [x] MIT License, installation and GitHub/Slack setup guide, copyable LLM prompt,
  and native README screenshots containing fictional isolated demo data only.
- [x] Document workspace-limited Slack registration and own-client setup without
  rebuilding; wider bundled-client distribution remains optional pending Slack setup.

## Shared-project discovery coverage

The user clarified the need as automatically visible projects after another owner
grants access. Implemented discovery uses actual GitHub reads for organizations,
repository collaborator owners and previously opened links. It does not provide
universal discovery: GitHub's documented API has no global list of all personal
boards shared with the viewer. A standalone board from a completely unknown owner,
or a personal public read-only board indistinguishable from public visibility,
needs one project link first. The owner is checked automatically thereafter.
Full discovery without that initial connection remains dependent on an appropriate
GitHub API; do not claim it is implemented. No invitation service or repository
invitation substitute was introduced. Cross-account sharing is tested with injected
APIs and isolated demo fixtures, not real permission changes.

## Public repository

- [x] Reviewed source, configuration, docs, fixtures and assets for private material.
  Credential/private-key/home-path scans and independent review found no blockers.
  Real workspace/channel names were removed from the historical public record.
  `.build/`, `dist/` and local QA artifacts are excluded.
- [x] Created the initial commit and published the public repository:
  [oddmundleikvoll/sprintwake-projects](https://github.com/oddmundleikvoll/sprintwake-projects).
  `origin` tracks the repository and `main` is pushed.
- [ ] Check hosted macOS CI, including release tests and the packaged ZIP artifact.

## Next: prepare and publish the first community release

1. Confirm the first public version/build in `Configuration/Release.json`
   (currently `0.2.0`, build `2`). Later public updates must increase the build.
   Keep the configured repository, feed URL and public signing key stable.
2. Resolve access to the existing Sparkle signing key in Keychain account
   **Sprintwake Projects Updates** and verify production-key signing. The last
   preview stopped while Keychain access was pending. The owner must handle any
   system approval. Never export the private key into source, scripts, logs or
   release assets.
3. From a clean committed tree, run `./scripts/test.sh`,
   `./scripts/test-release.sh` and `./scripts/release.sh`. Use an alternate
   `SPRINTWAKE_APP_PATH` if the default app is running. Review the generated
   ZIP, signed `appcast.xml`, checksum and commit/tag provenance before publishing.
   [Updates.md](Documentation/Updates.md) describes the exact process.
4. Publish the release and assets using the command printed by the release
   script. Confirm the GitHub HTTPS feed/archive URLs work and reference the
   intended version. The scripts prepare artifacts and a local tag; they do not
   upload or publish automatically.
5. Test a fresh download on another Mac or a separate macOS test account. Record
   any first-launch approval and Keychain prompts, and verify English/Norwegian,
   GitHub restoration and optional Slack. Current packages target the build
   Mac's architecture; Intel/universal distribution has not been qualified.
6. Install the first public release for existing local users; local development
   builds have public update checks disabled. Verify the first subsequent real
   update through the public feed, including the download indicator, signature
   validation and install/relaunch, on a separate test installation.

## Optional later work

- Developer ID signing and notarization if the owner later chooses Apple
  membership. This is not a prerequisite for community updates.
- Qualify Intel/universal packaging if that audience is to be supported.
- Observe long-duration GitHub/Slack token renewal live; injected tests already
  cover refresh, failure, cancellation and session isolation.
- Enable the bundled Slack client for other workspaces only after Manage
  Distribution and installation in another workspace are verified. The documented
  own-client path is available in the meantime.
- Additional product features are not scheduled by this release plan. Roadmaps,
  workflows, offline writes, widgets and richer Slack chat remain outside the
  implemented feature set.

## Release acceptance

The first public release is complete when reviewed/licensed source and matching
signed assets are published, CI succeeds, the feed resolves correctly, and a
fresh installation is verified with accurate architecture/first-launch guidance.
Public update delivery is fully verified only after a subsequent real update is
installed through that feed. Local/demo success alone does not establish this.
