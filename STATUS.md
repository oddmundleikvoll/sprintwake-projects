# Sprintwake Projects status

Updated 2026-11-05. This snapshot is current; the historical record below retains
earlier test counts, temporary blockers and superseded decisions. Continue from
[PLAN.md](PLAN.md), not an older outstanding-work entry.

## Current snapshot

- **App:** Sprintwake Projects 0.2.1, build 3, publicly released; native
  macOS 14+, Swift 6/SwiftUI.
  Branding and the S logo are complete. English is the first-launch default;
  saved language choices are preserved. English and Norwegian Bokmål are selectable.
  Existing bundle ID, preferences, Keychain services and Swift modules are retained.
- **GitHub:** board/list, projects, issues/drafts, assignments and conversations
  are implemented. The inaccessible-content defect was caused by repository
  authorization; same-account reauthorization restored all 12 live project items.
- **Assignment correction:** v0.2.1 fixes issue/PR add/remove failures with
  `Field 'id' doesn't exist on type 'Assignable'`. The response now selects `id`
  through `Node`. Both item kinds pass the schema regression and atomic-operation
  tests. The correction and release history are recorded in `CHANGELOG.md`
  and the matching public GitHub release notes.
- **Latest requested changes:** refreshed workspace/sidebar, project heading,
  board cards, sign-in and conversation surfaces share a light/dark indigo palette.
  Column plus buttons and ⌘N remain; no top-right New task button was reintroduced.
  Confirmed conversation sends still appear immediately.
- **Shared projects:** a separate sidebar section automatically discovers actual
  accessible boards through organizations, repository collaborator owners and
  previously opened links. Owner/New markers and account-scoped link/selection
  restoration are implemented. Discovery rotates up to 20 owners per minute,
  honors rate limits and cancels on logout. Unknown standalone owners and personal
  public read-only boards still need a link once; global discovery is not claimed.
- **Slack:** optional PKCE connection, history, plain-text sending and local
  channel selection are implemented. The authorized live workspace/channel and
  GitHub session restore across restart. General Slack distribution is pending.
- **Updates:** Sparkle download indicator, menu/settings, signed feed/archive
  verification and guarded install/relaunch are implemented. Community release
  preparation works without paid Apple membership. `--notarize` is optional.
- **Local app:** `dist/Sprintwake Projects.app` contains the refreshed design,
  shared discovery, earlier toolbar/conversation fixes and the assignment
  correction (local 0.2.0/build 2). It was preserved during public 0.2.1 packaging.
  Optimized packaging and deep strict signature verification passed.
  The stopped standard app was replaced and relaunched. After the user's macOS
  Keychain approval, the saved account, selected project, all 12 items and Slack
  history were restored. Earlier design verification
  covered light/dark appearance, default/minimum window sizing, search, board/list,
  conversation sending and sign-in layout, plus restoration of all 12 live items
  and Slack history. Local builds have public update checks disabled.
- **Publication:** source is public at
  [oddmundleikvoll/sprintwake-projects](https://github.com/oddmundleikvoll/sprintwake-projects)
  under the MIT License. README has installation/setup instructions, a copyable
  LLM prompt and native screenshots with fictional isolated demo data only.
  [Community release v0.2.1](https://github.com/oddmundleikvoll/sprintwake-projects/releases/tag/v0.2.1)
  (build 3, arm64/macOS 14+) is public, with signed ZIP/appcast and a portable checksum.
  [Hosted CI](https://github.com/oddmundleikvoll/sprintwake-projects/actions/runs/42042024414)
  passed for release source `cff54d1`. Anonymous HTTPS downloads, checksum and
  both archive/feed production-key signatures were verified. Fresh installation
  on another Mac and a subsequent update through the public feed remain unverified.

## Latest verification evidence

| Check | Latest recorded result |
| --- | --- |
| `./scripts/test.sh` | 121 tests in 14 suites passed; optional real Keychain test skipped in this run. |
| `./scripts/test-release.sh` | Passed community/notarized preflight, feed/key/metadata validation and valid/corrupt signature checks. |
| Issue/PR assignment correction | Original schema error reproduced through a read-only GitHub query; the Node fragment is accepted. Focused assignment tests and full 121-test/14-suite run pass; no real assignment writes used. |
| Community production package | Optimized ad hoc app built without Developer ID; public updater enabled, test mode off, deep strict signature and framework symlinks verified. |
| Real GitHub/Slack reads and restart | Passed with all 12 project items, selected project/channel and Slack history restored; no new OAuth flow required. |
| Language switching | Native demo retained unfinished text, selection and session while switching English/Norwegian; resources also worked outside the checkout. |
| Native updater installation | Disposable older/newer demo bundles completed signed loopback download, edit protection, replacement and relaunch. |
| Community ZIP/feed signatures | Published v0.2.1 ZIP/feed signed with the existing production Keychain key; private key was not exported. Anonymous downloads and latest-feed URL match the local verified artifacts; downloaded checksum and both archive/feed signatures pass public-key verification. Earlier disposable-key tests rejected corrupted archives. |
| Independent reviews | Access, localization, Slack and updater/release findings addressed; no material findings left in the latest reviews. |
| Conversation changes | Immediate local GitHub-message insertion verified on the native demo board/full conversation; ⌘N still works and toolbar task button is absent. Slack stale-history protection and partial-placement reconciliation passed injected tests. |
| Latest standard package | Assignment correction packaged with `./scripts/build-app.sh` using a staging app path, then installed while the standard app was stopped. Optimized build and deep strict signature passed; packaged executable contains the corrected Node fragment. After the user's macOS Keychain approval, native restart restored the saved account, selected project, all 12 items and Slack history. No real assignment write was used. |
| Design refresh | Native isolated demo passed dark/light visual checks, default/minimum sizing, search, board/list and local conversation send. Sign-in card checked in light appearance. Independent review found no material defects; increased-contrast styling is implemented but not manually exercised. |

GitHub task/message mutations and Slack posting were verified with injected APIs
and isolated native demos. They were not exercised against the user's real tasks
or channel. Production-key signing now succeeds through the existing Keychain
account; the private key was neither exported nor changed.

Hosted macOS CI passed tests, release checks, optimized app packaging and ZIP
artifact upload for release source `cff54d1`. Initial runs exposed a Swift 6.3.3
compiler crash on bound main-actor Binding setters; explicit setter closures
resolved it. Local Swift 6.4 had not exposed that crash. There is no separate
lint or formatter command.

## Remaining work, in order

1. Test a fresh public download on another Mac or separate macOS test account,
   including first-launch approval, English/Norwegian and GitHub/Slack restoration.
   Public transport and signature verification are complete; this is separate
   from fresh-install acceptance.
2. Move existing local installations to the public release if desired; development
   builds do not check the public feed. Verify the v0.2.0-to-v0.2.1 public update
   on a separate test installation.
3. Optional broader Slack distribution: own-client setup is documented, but the
   bundled registration needs distribution and another-workspace verification
   before it can be offered generally.

See [PLAN.md](PLAN.md) for completion criteria and
[Updates.md](Documentation/Updates.md) for release commands. Apple enrollment,
Developer ID and notarization are not required for the selected community path.

## Known limits

- GitHub has no documented global list of all boards shared with a user. Automatic
  discovery uses organization/repository connections and previously opened links.
  Standalone unknown owners and personal public read-only boards need a link once.
  No simulated accept/decline or separate invitation service is implemented.
- Community builds may require manual first-launch approval and Keychain prompts.
  No Gatekeeper protection or quarantine handling has been bypassed.
- Fresh installation on another Mac and the public GitHub update path remain
  unverified. Current builds target the host architecture; Intel/universal
  distribution is not qualified.
- Long-duration live GitHub/Slack token renewal has not been observed; injected
  tests cover token rotation and failure/cancellation behavior.
- The external GitHub OAuth registration still displays Fjord Projects. Real
  column editing and complete participant administration open GitHub.
- Roadmaps, workflows, offline writes, widgets and richer Slack features are not
  implemented. They are outside the current first-release plan.

## Historical implementation and verification record

The entries below preserve evidence from earlier iterations. Temporary login or
Keychain waits, old test counts and the earlier mandatory-Apple release requirement
are historical; the current snapshot above supersedes them.

First native implementation built and exercised. The workspace started empty;
there was no existing manifest, test runner or CI. Swift 6 and the macOS SDK are
installed. SwiftUI, Foundation and Security provide the app platform; Sparkle
2.10.1 is now bundled for signed app updates.

The GitHub CLI is authenticated, but its existing token does not include the
Projects scope. The implementation will not modify CLI authorization.

OAuth registration `Fjord Projects` was created on the owner's GitHub account
after explicit action-time approval. Device Flow and expiring tokens are enabled,
wildcards are off, and callback is `http://127.0.0.1` (unused by Device Flow).
Public Client ID is configured in the app and `Configuration/GitHub.json`.
No Client Secret was generated. No private token is written to this repository.

### Implemented

- Device Flow, refresh tokens, Keychain persistence/restoration, local logout.
- User/organization projects and direct project URL lookup; project creation and
  deletion with exact-name confirmation. Repository issues/PRs survive deletion.
- Paginated board/list with labeled views, search, real single-select fields,
  status changes and content editing with a pre-save conflict check.
- Per-column plus opens issue/draft creation with preset placement, repository
  lookup and initial assignees. Confirmed creation retains partial-success warnings
  and the issue URL when linking/placement/reload fails.
- Quick assignee picker on cards, table and editor, repository suggestions and
  username lookup. Atomic issue/PR add/remove; fresh merge for draft assignees,
  fail closed when inaccessible, explicit warning about concurrent draft edits.
- Empty unassigned group hidden; actual missing/unknown values remain visible.
- Column menus and manager with counts and delete impact explanation. Real column
  creation/deletion opens GitHub; native full-array replacement stays disabled.
  The isolated demo supports direct column creation/deletion.
- Grant an individual user READER/WRITER/ADMIN; full access list opens GitHub.
- Chat backed by self-assigned drafts, directly in the board column and in a
  separate larger conversation view; shared selection remembered per project/field.
- Manual/focus/30-second active-window refresh and an independent local demo.
- Packaged `dist/Sprintwake Projects.app`, ad-hoc signing, icon and macOS CI.

### Verification

- `./scripts/test.sh`: 43 tests passed, 7 suites. Covers placement/assignee inputs,
  stale results/logout, permissions, partial success, project lifecycle, grouping,
  atomic issue assignment and fail-closed draft assignment.
- `FJORD_KEYCHAIN_TEST=1 ./scripts/test.sh --filter KeychainTests`: actual isolated
  Keychain save/update/read/delete passed with cleanup.
- `./scripts/build-app.sh`: final release arm64 app rebuilt after iteration/review fixes,
  signed and launched successfully. No non-system library dependencies.
- `codesign --verify --strict --verbose=2 "dist/Sprintwake Projects.app"`: valid signature/bundle.
- Native UI: local demo issue created from In Progress plus button, preselected
  status retained and chosen assignee displayed; another assignee added from
  card popover. Inline board message sent and immediately displayed. Column
  created/deleted with impact confirmation; project created/selected/deleted
  with exact-name confirmation, returning to the remaining project.
- Final package opened as a separate demo bundle with independent preferences and
  `FjordDemoMode=true`. Board layout and inline message posting passed again.
  Screenshot: `.build/fjord-board-iteration.png`. No real project was modified.
- Live read-only GitHub schema checks confirmed single-select option `id`, draft
  `assigneeIds`, and collaborator input/payload.
- `git diff --check`: clean.
- Public OAuth build configuration verified by rebuilding the app, extracting
  `GitHubOAuthClientID` from Info.plist, and checking the package signature.
- On 2026-11-04 the user completed GitHub consent themselves. Fjord received the
  real session and loaded project 1 with 12 active items, including private
  issues, pull requests and a draft. Both board and list were checked live.
- Manual refresh fetched fresh data successfully. Quit Fjord, confirmed its
  process exited, relaunched the packaged app: it restored the real session
  without another login and fetched the same selected project automatically.
- Created the dedicated `Samtale` status option using GitHub's own New column UI.
  Refreshing Fjord fetched the new option and enabled the real chat composer.
  The project still contains 12 active items; the conversation starts empty.
- Non-fatal linker warnings refer to missing optional CLT developer-framework
  search paths. All compile/link/package/test commands above completed.

### Outstanding

- Initial independent review found concurrent option replacement could remove
  others' new columns, and partial chat placement was described too certainly.
  The live replacement mutation has been removed; chat now reports unconfirmed
  placement without claiming the draft is necessarily unassigned. Regression
  tests pass. The new iteration received an independent review and follow-up;
  no correctness blocker remains after the draft-read, loading-state and
  late-notice fixes.
- OAuth, actual private-project reads, external column synchronization, and
  persistence across a real app restart are verified. Task-content/status writes,
  collaborator grants and message posting remain covered by isolated tests and
  the local demo rather than writes against the user's real tasks/conversation.
  Long-duration refresh-token renewal has not been observed live.
- The updated ad-hoc build is waiting for macOS Keychain access on relaunch.
  SecurityAgent started; computer automation is prohibited from accessing that
  system dialog. User handoff requested. Existing stored credentials were not
  deleted. Stable distribution signing is still required for seamless updates.
- No notarization/distribution certificate, offline writes, roadmap/workflows,
  complete native participant listing, or macOS widgets in this first version.


### 2026-11-04 — Initial branding and private item visibility (historical)

- Initially renamed the visible app to **Sporverk** (superseded below by
  **Sprintwake Projects**), with a route-shaped S logo in the
  sidebar, login, loading view and packaged app icon. Editable SVG and PNG
  deliverables are in `Branding/`. This initial iteration produced
  `dist/Sporverk.app`; see the current output in the next section.
- Preserved `no.oddmund.Fjord`, Keychain service, local preferences, OAuth Client
  ID and Swift module names. The external OAuth registration is still Fjord Projects.
- Confirmed the reported defect in the running app, then with a read-only GitHub
  diagnostic: the active token has `project, public_repo, read:org, read:user`,
  without `repo`; 11 issue/PR items have null content, while the draft is readable.
  No credentials or item bodies were logged, and no GitHub data was modified.
- Hidden items now show an explanation/count and **Gi tilgang …**. Device Flow can
  replace a signed-in session with explicit private-repository authorization.
  Failure/cancellation keeps the old credential; a different account is rejected;
  success invalidates old reads and refreshes the selected project.
- The private-repository choice is remembered. Access can also be opened from the
  account menu. Real repository authorization remains a user-approved step;
  changing a local label cannot reveal content that GitHub has redacted.
- `swift build` and focused authorization/API tests passed. Full `./scripts/test.sh`
  passed: 49 tests, 8 suites. `./scripts/build-app.sh` produced the release app;
  strict codesign verification and bundle metadata checks passed.
- The new app launched and restored the existing account and selected project.
  Native UI confirmed Sporverk branding, the 11-item explanation and the access
  sheet. An independent review caught inherited disabling of the access sheet;
  the blanket disabling has been removed before final packaging.
- The GitHub consent was completed externally while verification continued. A new
  read-only diagnostic confirmed `project, read:org, read:user, repo`, with all 11
  issue/PR contents now returned. The board and list show their actual titles,
  repository and assignees. The hidden-item banner is gone; no GitHub task data
  was changed by the agent.


### 2026-11-04 — Sprintwake Projects and English/Norwegian

- The user requested an English name for a future public GitHub repository and
  chose **Sprintwake Projects**, with Sprintwake as the short name. The approved
  S logo is retained. Current app output is `dist/Sprintwake Projects.app`.
- English is the development language, with English and Norwegian Bokmål resource
  tables for interface and core messages. The sign-in screen and settings offer
  System language / English / Norsk (bokmål); the choice persists.
- Text updates through observable language settings without resetting views or
  discarding unsaved forms. Repository/project content remains in its original
  language. Unsupported system languages fall back to English.
- The package declares English localization and bundles localized resources;
  packaging copies the companion resource bundle into Contents/Resources.
- README.md is now English, with README.nb.md preserving the Norwegian guide.
  App identity, existing session, OAuth registration and internal Swift names
  remain compatible. No repository has been published by this task.
- `./scripts/test.sh`: 55 tests passed across 9 suites, including table parity,
  format arguments, call-site lookup coverage, language fallback, session
  preservation and authorization. Optional real Keychain test skipped.
- `./scripts/build-app.sh` and strict codesign validation passed for the final
  release package. Bundle name/identifier and both en/nb resource tables verified.
- A separately signed demo bundle was copied outside the repository/build paths
  with its own bundle identifier and `FjordDemoMode=true`. It launched using only
  the packaged localization resources and did not read the real session.
- Native UI: switched Norwegian → English → Norwegian while a new-task sheet
  held an unsent title. All sheet labels updated immediately and the typed title
  remained unchanged. English sign-in, private-repository explanation, settings,
  board labels and localized dates were verified. Project sample content kept its
  original language, as intended.
- English preference persistence passed across a restart of the separate demo
  bundle. After the final release launch, the first Keychain read reported an
  authorization failure. The user completed GitHub authorization themselves;
  the final Sprintwake Projects app now shows the selected real project with
  all 12 items (11 issues/PRs and one draft), actual titles and assignees, and a
  successful sync with no inaccessible-item banner. No task data was changed.
  Automatic restoration of this newly authorized session has not been retested;
  the app was left open on the user's board.

### 2026-11-04 — Optional Slack conversation source

- Added an optional Slack channel conversation pane for the board and full
  conversation view. GitHub draft chat remains the default and is unchanged.
- Added native public-client OAuth with PKCE, exact custom callback validation,
  workspace/user verification, rotating refresh-token storage in Keychain and
  per-GitHub-account session isolation. Slack credentials are never stored in
  preferences, files or logs.
- Added paginated channel/history reads, plain-text posting with explicit
  delivery-uncertainty handling, local project/channel bindings, Slack links for
  threads/files, and a separate in-memory demo API.
- Added English and Norwegian UI strings, `Configuration/Slack.json` and a Slack
  app manifest/setup guide. Created the Sprintwake Projects public-client Slack
  registration in the owner's test workspace using the included manifest. Slack accepted PKCE and
  token rotation; OAuth settings show the exact custom callback. Bundled its
  public Client ID without reading or unmasking private app credentials.
- `./scripts/test.sh`: 85 tests across 11 suites passed. Optional Keychain test
  skipped. Includes callback/PKCE, token rotation and concurrent refresh,
  cancellation/logout, account/project isolation, stale reads, membership,
  unavailable channel reconciliation, pagination, posting confirmation,
  uncertain delivery, profile lookup rate limits and both localization tables.
- Independent review found a stale saved-channel fallback after a successful
  list and recommended channel-ID deduplication. Both are fixed and reviewed;
  no material review findings remain.
- `./scripts/build-app.sh`: release build and strict signature verification
  passed. Checked compatible bundle ID, public Slack Client ID, callback scheme,
  and en/nb companion resources in the package. Existing non-fatal CLT linker
  search-path warnings remain.
- Copied a separately identified, signed demo bundle to `/tmp` with
  `FjordDemoMode=true`. Native UI verified Slack source/channel selection,
  locally confirmed posting and cleared composer, inline board panel, and
  Norwegian → English with channel and messages preserved. No real Slack
  message or GitHub task was written.
- The user approved the live Slack OAuth dialog themselves and selected
  the selected test channel in the owner's test workspace. The app completed PKCE exchange and identity
  verification, loaded channel history and resolved author names. No message
  was sent by the agent. The existing GitHub session and all 12 project items
  also survived the updated app's first restart.
- The final rebuilt app restarted with both GitHub and Slack sessions, the same
  selected project and the selected test channel, and freshly loaded Slack messages. It
  initially showed the loading view while `SecurityAgent` was running; the user
  reported no visible dialog, and startup completed without another OAuth flow.
  No system authentication dialog was inspected or operated. Long-duration live
  token rotation remains covered by injected tests rather than an elapsed live
  refresh. Stable distribution signing is still needed for released updates.

### 2026-11-04 — Signed app updates

- Added Sparkle 2.10.1, pinned by exact version and `Package.resolved`, with the
  complete bundled license. Core GitHub/Slack code remains independent of it.
- Official releases automatically check a signed feed at the intended
  `oddmundleikvoll/sprintwake-projects` release URL. A new version produces a
  download button in the sidebar/login view. Global Check for Updates and a
  localized Settings section expose manual checks and the automatic-check choice.
- Installation is user initiated; automatic installation and profile telemetry
  are disabled. Both feed/archive signatures and verification before extraction
  are enabled. The production update private key was generated only in Keychain
  account `Sprintwake Projects Updates`; only the public key is in Release.json.
- Unfinished task/item/project forms, conversation composers and sign-in token
  input register only dirty UUIDs. An approved restart waits for active writes or
  authorization. Unsent changes offer Keep editing or explicit Discard and update.
  Keeping edits returns to the workspace; repeated installer actions cannot
  bypass the pending gate, and cancellation clears the continuation.
- Version/build metadata is now `Configuration/Release.json` (0.2.0/build 2).
  Release scripts require clean committed source, a verified Developer ID identity
  and notarization profile; they sign nested helpers, notarize/staple, create and
  verify ZIP/appcast/checksum, and bind the release tag to the built commit. The
  final publishing command is printed for review and is not executed.
- Local builds disable public updater networking. Explicit test builds have a
  separate bundle ID, local demo data, no Slack callback and loopback-only HTTP.
  Packaging preserves framework symlinks and refuses to overwrite a running app.
  CI runs Swift and release tests and uploads a ZIP to preserve permissions.
- `./scripts/test.sh`: 91 tests across 12 suites passed; optional real Keychain
  test skipped. `./scripts/test-release.sh` passed, including appcast metadata,
  identity/URL/key validation, valid signature acceptance and corruption rejection.
  The release validator also accepted a real Sparkle-generated signed appcast.
- Native isolated E2E: older 0.2.0/build 2 found the signed loopback release and
  displayed the download badge, downloaded and verified the signed ZIP, protected
  unsent text through Keep editing and repeated install attempts, and completed
  replacement/relaunch to 0.2.1/build 3 when editing finished. Settings confirmed
  the installed version. Real GitHub/Slack credentials/data were not used. The
  test server/processes were stopped and the disposable private test key removed.
- Independent review findings on unsaved edits, source/tag provenance, metadata
  validation and documentation have been addressed and re-reviewed. No material
  findings remain. Final `./scripts/build-app.sh` optimized package and strict
  deep signature verification passed; production identity/local mode, public
  metadata, framework symlinks and license were inspected.
- No public repository/release was created or uploaded. The owner does not yet
  have Apple Developer membership, so actual Developer ID/notarized GitHub update
  validation remains pending. Existing local installs need the first official
  build before receiving later public updates.
- After the user unlocked the Mac, final native verification confirmed version
  0.2.0/build 2, restored GitHub account/project with all 12 items and a successful
  fresh sync, and the saved Slack connection to the owner's test workspace with the selected test channel
  selected and history loaded. No new OAuth flow was required. Settings correctly
  explains that public automatic updates are enabled in official release builds.
  The app was left open on the real project board; no remote data was changed.

### Community releases without paid Apple membership (2026-11-04)

- Inspected Sprintwake Studios' local Sparkle/release implementation. Ed25519
  update signatures are independent of Apple Developer ID and notarization;
  Studios' evidence is local, and no public Studios release was inferred.
- `./scripts/release.sh` now defaults to an ad hoc-signed community app with
  signed Sparkle feed/archive updates. Apple membership is optional. Explicit
  `--notarize` retains strict Developer ID/profile checks, hardened runtime,
  timestamps, notarization and stapling; failures never fall back silently.
  This supersedes the earlier mandatory-Apple release requirement above.
- HTTPS, signed feeds/archives, verification before extraction, dirty-edit/write
  protection and isolated test/demo behavior are preserved. Ordinary local
  builds still do not contact the public update server. First installation of a
  community build may require the user's macOS approval; no Gatekeeper settings
  or quarantine attributes were changed. Ad hoc updates may prompt for Keychain.
- `./scripts/test-release.sh` passed, including actual release preflight in a
  disposable clean Git repository: community mode reaches Sparkle setup without
  invoking mocked Apple tools, while `--notarize` rejects a missing Developer ID.
  Release mode rejects a missing update key. Valid/corrupt signature checks pass.
- `./scripts/test.sh --filter UpdateConfigurationTests`: 6 tests passed.
  Full `./scripts/test.sh`: 91 tests in 12 suites passed, optional real Keychain
  test skipped. Optimized packaging with `SPRINTWAKE_RELEASE_BUILD=1` and
  `SPRINTWAKE_NOTARIZE=0` passed without Developer ID. Deep strict code signature,
  public update metadata, signed-feed requirements and framework symlinks checked.
- A disposable demo copy of that package was archived and signed with a temporary
  test key using real Sparkle tools. Feed/archive verification passed and a
  corrupted ZIP was rejected. Temporary bundle/archive/private test key removed.
  The installed real app and Studios were not replaced or launched for this QA.
- An additional preview using the production update key waited on Keychain access
  and was stopped. No key was exported or changed. That Keychain permission still
  needs completing when preparing the first real release. Independent review
  found no material issues. Final task diff and whitespace checks passed.
- No public repository/release was created or uploaded. This checkout still has
  no initial commit or remote; the first GitHub release and its signed assets
  remain to be published before users can receive public updates. Fresh installs
  on other Macs were not tested. Existing local installs need the first public
  release build before later in-app updates.


### 2026-11-04 — Immediate conversation sends and toolbar cleanup

- Removed the top-right New task button; column plus buttons and ⌘N still open
  task creation. Native demo confirmed the plus buttons remain visible and ⌘N
  opens task creation.
- GitHub chat now returns and inserts the mutation-confirmed draft, including
  actual content/creator/timestamp, immediately after confirmed placement. A full
  project read is no longer required to show a successful send. Partial placement
  keeps the confirmed draft and reconciles once without repeating creation.
- Slack history started before a confirmed send is discarded rather than erasing
  that message. Injected regression tests cover this race, failed sends, sign-out,
  authoritative message metadata and accepted-but-lost placement responses.
- Final ./scripts/test.sh: 97 tests in 12 suites passed; optional Keychain test
  skipped. ./scripts/test-release.sh passed. Optimized preview packaging and deep
  strict signature verification passed. Only existing CLT linker warnings remain.
- An isolated, separately identified demo outside the checkout confirmed a new
  GitHub message immediately appeared in the full conversation and board, with
  its composer cleared. The toolbar button was absent and ⌘N opened task creation.
  Additional native Slack channel selection hit a CUA timeout and was not
  completed; Slack confirmation/race behavior is covered by injected tests.
  No real GitHub/Slack message, invitation or permission was changed.
- Independent review found no material code defects. The suggested partial-
  placement reconciliation test and durable record updates are included.
- User clarified invitations mean the Projects board, not repositories. Official
  GitHub Projects API documentation exposes collaborator grants but no pending-
  invitation inbox or accept/decline operations. Automatic cross-account alerts
  and invitation responses remain pending a delivery design; no repository
  invitation substitute or new service was introduced. See PLAN.md.
- Updated local app is dist/Sprintwake Projects Preview.app. The existing running
  app was not replaced; no public release/version bump was made.

### 2026-11-04 — Apply the fixes to the standard app

- The user reopened the standard app and still saw New task in the toolbar.
  Process-path and native UI checks confirmed it was the older standard build;
  the preceding task had packaged only Preview.
- After confirming the composers were empty and no edit sheet was open, quit
  the standard app normally, verified its process had exited, and ran
  `./scripts/build-app.sh`. Optimized packaging and deep strict signature
  verification passed. No source changes or additional tests were needed.
- Reopened the standard app and observed the real board: no top-right New task
  button, the same account/project with 12 items, and the saved Slack channel
  with loaded history. Startup initially waited for saved sign-in; no system
  authentication dialog was inspected or operated by the agent.
- At the user's request, moved Sprintwake Projects Preview.app to Trash and
  verified it no longer exists in dist. The updated standard app remains open.
  No GitHub/Slack data was changed and no release was published.


### 2026-11-04 — Automatic shared-project discovery

- Added a separate Shared projects sidebar catalog with owner and New markers.
  Discovery uses organization membership, repository-collaboration owners and
  canonical previously opened project links, then verifies project access through
  GitHub. Public visibility alone is not treated as a personal share.
- Catalog reads do not change the selected board. Canonical links, seen IDs and
  shared selection are isolated by GitHub identity and reverified at restart.
  Transient source failures preserve affected prior entries and show a notice;
  successful reads reconcile removed access. Demo state stays in memory.
- Active discovery rotates through at most 20 owners per minute and caches
  repository-owner connections for ten minutes. Manual refresh bypasses that
  cache. HTTP/GraphQL quota errors stop fan-out and honor reset/retry-after even
  for manual retries. Logout/reauthorization cancel the owned discovery Task.
- ./scripts/test.sh: 120 tests in 14 suites passed. Includes private/public access
  classification, owner/project pagination, new/revoked shares, transient org
  errors, account isolation, shared-selection restoration, stale opens/writes,
  85-owner scan rotation, logout cancellation and quota/retry handling. Optional
  Keychain round-trip skipped. ./scripts/test-release.sh passed.
- Independent review identified unbounded owner fan-out and uncancelled reads.
  Both were fixed and retested; final review found no material remaining defects.
- An isolated, separately identified /tmp demo showed the discovered shared board
  and owner/New marker automatically. Opening it removed New, loaded its real
  fixture data and preserved selection through Cmd-R. No real task, message,
  invitation or permission was changed. Disposable demo process/bundle removed.
- A read-only GitHub CLI query validated the repository affiliation/owner lookup
  against the live schema; only result counts were printed, no tokens.
- Final optimized standard packaging and deep strict signature verification
  passed. After relaunch the user approved macOS Keychain access themselves.
  Final native UI confirmed the original account/project, all 12 items, loaded
  Slack history and Shared projects with no discovery error. It currently reports
  no shared boards found through the account's connections; this does not claim
  that unknown standalone personal shares can be enumerated. No Preview app was
  created. The standard app remains open on the original board.
- Coverage remains bounded by GitHub's API: a standalone board from an unknown
  personal owner, or a personal public read-only board indistinguishable from
  public visibility, needs a link once. That owner is checked thereafter. No
  universal discovery, backend, extra OAuth scopes or invitation acceptance is
  claimed. No public release/version bump or upload was made.


## 2026-11-04 — Workspace design refresh

- Centralized adaptive opaque surfaces in `WorkspaceStyle.swift`; added a quieter
  sidebar, larger project heading, colored column badges, raised task cards with
  pointer feedback, and matching sign-in/chat surfaces. Removed a duplicate
  language label on sign-in. Existing state and mutation paths are preserved.
- `swift build`, `./scripts/test.sh` (120 tests/14 suites),
  `./scripts/test-release.sh`, optimized app packaging and deep strict signature
  verification passed. Only existing CLT linker search-path warnings appeared.
- Checked the isolated demo outside the checkout: light/dark palette, compact
  window, search filtering, list, board and a locally confirmed conversation send.
  No real GitHub or Slack writes were used. Visual-only changes use native demo
  verification rather than implementation-mirroring unit tests.
- Replaced the stopped standard app; retained the prior app under
  `/tmp/sprintwake-design-before` for this session. After macOS Keychain approval,
  native restart restored the selected live project with all 12 items and Slack
  history. The new heading/search/sidebar were verified in the live UI.


### 2026-11-04 — Public repository preparation

- New installations start in English; stored language choices, including system,
  remain effective. Added regression coverage for missing/invalid and saved values.
- Replaced Norwegian demo content with a fictional Website launch workspace,
  English tasks and draft conversations. Captured board/list/Slack windows from a
  separate `FjordDemoMode=true` bundle outside the checkout, with its own identity.
  No real session or project was opened for these screenshots.
- README leads with an example screenshot and installation instructions; added
  GitHub/Slack connection instructions and a copyable LLM setup prompt. Slack's
  workspace-only status and own-client setup are explicit. Added MIT License.
- Removed real workspace/channel names from the historical public record.
- `./scripts/test.sh`: 121 tests/14 suites passed after correcting a pre-existing
  hardcoded Norwegian board-grouping expectation. `./scripts/test-release.sh`
  and `swift build -c release` passed. Local CLT search-path warnings remain.
- Independent review found no material defects. Created the initial commit and
  pushed the reviewed files to the public GitHub repository. Hosted CI and
  production release preparation remain in progress; no fresh-install/public-update verification is claimed.


### 2026-11-04 — First public community release

- Published the MIT-licensed repository and community release v0.2.0/build 2 from
  clean source `a189bc60124c4bccda80104f09e9dd6775044c9d`. The remote tag matches
  that source. Hosted macOS CI run 41911644644 passed tests, release checks,
  optimized packaging and ZIP artifact upload.
- Fixed Swift 6.3.3 IRGen crashes in SwiftUI Binding setters using explicit
  main-actor closures. Local full suite: 121 tests/14 suites passed; independent
  review found no material defects. No test or compiler check was skipped.
- Included the MIT and Sparkle licenses in the signed app resources. Made the
  checksum portable by using the archive basename instead of the build path.
- Production Keychain signing succeeded. ZIP and appcast signatures, version,
  identity, updater mode, en/nb resources and framework symlink were verified.
  No production private key was exported or changed.
- Published ZIP, portable SHA-256 checksum and signed appcast. Anonymous HTTPS
  downloads (including the latest feed URL) match the local verified artifacts;
  downloaded ZIP checksum and Ed25519 signature pass. The downloaded ZIP was
  extracted with ditto and its app passed deep strict code-signature verification.
- README now links directly to the release and prominently explains built-in
  GitHub draft chat, optional Slack and no Sprintwake server/database to host.
  Screenshots use fictional demo data; the setup prompt leaves authorization
  under the user's control and verifies connections without real test writes.
- Remaining qualification: fresh install on another Mac/separate account, a later
  public update, Intel/universal packaging and general bundled Slack distribution.

### 2026-11-05 — Assignment correction and public patch release

- Reproduced `Field 'id' doesn't exist on type 'Assignable'` through a read-only
  GitHub query. Issue/PR add/remove responses now select `id` through `Node`;
  atomic operations and other assignees are preserved. The regression failed
  before the fix and passes for both issues and pull requests afterward.
- Full local verification passed: 121 tests/14 suites and release configuration
  tests. Independent correctness/release reviews found no material defects.
  No real GitHub task or Slack-message writes were used as tests.
- Published v0.2.1/build 3 from `cff54d11e5016d438e565c1168f11065d11e2c51`,
  with a matching annotated remote tag and passing hosted macOS CI run 42042024414.
  Added `CHANGELOG.md`; its patch entry supplies the GitHub release notes.
- Used the existing production Keychain signing key without exporting it.
  Public ZIP/checksum/feed and latest-feed URL match the local signed artifacts.
  Downloaded archive and feed signatures pass public-key verification; the
  extracted app passes deep strict code-signature verification. ZIP SHA-256:
  `16a7c77a5adf05dd21f2f459423dfa96d8b663444740f8ad3c8b6e1d8427edd4`.
- Public package is arm64/macOS 14+, ad hoc signed with updater enabled, en/nb
  resources and both licenses. The running local app was preserved. Fresh install
  on another Mac and installation through the public feed remain unverified.
