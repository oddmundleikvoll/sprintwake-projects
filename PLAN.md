# Sprintwake Projects plan

Updated 2026-11-04. [STATUS.md](STATUS.md) contains the current snapshot and dated
verification history. [CONTEXT.md](CONTEXT.md) records architecture and decisions.
This plan records publication and the remaining distribution verification.

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
- [x] Hosted macOS CI passed for release source `a189bc6`, including tests, release
  checks, optimized app packaging and the ZIP artifact (run 41911644644).

## Published community release

- [x] Version 0.2.0/build 2 published from clean source `a189bc6`, with the matching
  remote tag and passing macOS CI. Future public updates must increase the build.
- [x] Existing Sparkle Keychain signing key used successfully; ZIP/feed signatures
  verified. The private key was not exported or changed.
- [x] Production app packaged with en/nb resources, both licenses, safe updater
  settings and preserved framework symlinks. The standard installed app was not replaced.
- [x] Published ZIP, signed appcast and portable SHA-256 checksum to
  [v0.2.0](https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.2.0).
- [x] Anonymous public HTTPS downloads, including the latest feed URL, match the
  local verified artifacts. Downloaded ZIP checksum/Ed25519 signature and the
  extracted app's deep strict code signature pass.

## Next: qualify fresh installation and future updates

1. Test a fresh public download on another Mac or a separate macOS test account.
   Record first-launch approval and Keychain prompts, English/Norwegian, GitHub
   restoration and optional Slack. The published package is arm64/macOS 14+;
   Intel/universal distribution has not been qualified.
2. Existing local users can install the first public release to receive future
   updates; local development builds have public update checks disabled. When a
   later release exists, verify an actual public-feed update on a separate test
   installation, including download indicator, signatures and install/relaunch.

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
