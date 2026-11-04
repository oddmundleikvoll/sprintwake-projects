# Domain and architecture

Sprintwake Projects is a native client for GitHub Projects v2. GitHub is authoritative for
projects, fields, issues, pull requests and drafts. Layout and the public OAuth
Client ID are local preferences. Credentials live only in macOS Keychain.

The developer's public OAuth app registration is Fjord Projects. Its public
Client ID in `Configuration/GitHub.json` is bundled by the packaging script;
an environment override supports forks. No Client Secret is generated or used.

A project owner is a GitHub user or organization. URL lookup also supports
projects shared by another owner. A project item wraps a draft, issue, pull
request, or inaccessible content. Board columns are options of an existing
single-select field. Empty unassigned groups are hidden; actual unassigned or
unknown-option items stay visible in a labeled group. The app never creates
or assumes a fixed set of statuses.

The core library owns network, session and workspace state. SwiftUI renders that
state and sends user actions back. Mutations are confirmed by GitHub. Generation
checks prevent obsolete requests from repopulating a signed-out session or a
different project. The demo uses an independent in-memory API and no credentials.

Project chat is a presentation of DraftIssue items in one selected single-select
option (normally a new `Samtale` column). Message creation assigns the current
GitHub user's node ID; the draft creator supplies authorship, not the mutable
assignee list. The body retains the full message; title is a short preview.
Creation and column placement are separate mutations, so a failed placement
after successful creation is reported as a saved draft with unconfirmed placement.
It may already be in the chat if only the HTTP response was lost.
The chat mutation returns the created draft's ID/content/creator/timestamp. After
confirmed placement AppModel inserts that item directly, without a full snapshot
fetch. A partial placement keeps the confirmed draft and performs a reconciliation
read; failed reconciliation never invites another creation. Slack history reads
capture a message generation so a pre-send response cannot erase a confirmed send.

Column creation opens the project's GitHub board. The public API only replaces
the full option collection, with no conditional append. The native client never
does this replacement, which could remove another admin's concurrent edits.
Only the isolated demo adds/deletes columns in memory. Participant grants use GitHub's
administrator-checked collaborator mutation. The full role list remains in
GitHub Manage access because ProjectV2 has no documented collaborator query.
Shared-project discovery uses organization membership, owners of repositories in
which the viewer is a collaborator/member, and canonical previously opened links
as candidate owners. SharedProjectDiscovery then queries real project access per
owner. It includes private readable boards, public writable boards, member-org
boards and explicitly opened links; unrelated public visibility is not a share.
GitHub has no documented global shared-project list, so standalone unknown owners
and personal public read-only boards still need one project link initially.
There is no new backend, scope expansion or simulated invitation acceptance.

AppModel owns a separate account-scoped shared catalog with owner/New rows in
the sidebar. Catalog refresh does not change board selection or busy state for
board writes. It runs every minute while active; candidate repository owners are
cached for ten minutes, with manual refresh bypassing the cache. Session/read and
mutation generations reject obsolete results. A successful owner read reconciles
removed access; a failed owner read retains its prior entries and shows a notice.
Project owners are scanned in rotating batches of at most 20 per pass. Unscanned
owners retain their prior entries; initial remaining work is indicated in the UI.
HTTP/GraphQL rate limits stop the scan and enforce reset/retry-after cooldown,
including manual retries. AppModel owns and cancels the discovery Task on logout
and reauthorization; cancellation is checked before subsequent owner/page reads.
Canonical links, seen IDs and shared selection are stored per GitHub identity;
titles and invitation query strings are not persisted. Links/selection are verified
again before restoration. Demo discovery and preferences stay in memory.


Project creation resolves the owner node ID before createProjectV2. Deletion
requires the exact visible project title and GitHub authorization. Repository
issues/PRs survive project deletion. Confirmed project writes remain successful
when the following fetch fails; old project loads cannot replace the new selection.

NewItemRequest captures the intended project, repository, assignees and column
field/option before sending. Real issues are created in the repository, linked
to the project, then placed. Drafts are created in the project, then placed.
A failure after confirmed creation returns ItemCreationResult with a warning and
issue URL rather than asking the caller to create again. Ambiguous initial
creation responses are still a network limitation; inspect GitHub before retrying.

Assignment suggestions combine current project assignees, the viewer and repository
assignableUsers. Issues/PRs use atomic add/remove-assignee mutations. DraftIssue
only exposes full-array replacement; read current assignees immediately first,
fail closed when the draft is inaccessible, and show the remaining concurrency
limitation in the picker. No claim of a cross-client transaction is made.

The board and full conversation view share the conversation option preference,
scoped by project and grouping field. The board renders drafts in that option as
messages with a composer beneath them; ordinary issues/PRs remain ordinary cards.


Sprintwake Projects is the user-facing name; Fjord remains the Swift module/executable build
name and the established bundle/Keychain identity, preserving existing sessions
and preferences. Packaging produces dist/Sprintwake Projects.app. Branding contains editable
SVG sources and generated PNGs; the app and icon renderer share the route-shaped S.
The existing external OAuth app remains Fjord Projects.

GitHub redacts repository-backed item content when a token can read the project
but lacks access to the source repository. A project with hidden items shows a
repository-access explanation and an explicit Device Flow reauthorization action.
The live defect was confirmed from a token with project/public_repo but no repo.
Reauthorization validates the same account, keeps the old credential on failure
or cancellation, replaces it only after validation, invalidates old reads and
refreshes the current project. Private-repository choice is remembered; no scope
is expanded without user authorization. Missing repository membership or SSO can
still leave items redacted after authorization.


English is the development language and the first-launch default, independent
of the Mac's language. `AppLanguage` resolves system/en/nb and preserves explicit
choices in `appLanguage`, including a previously saved system preference.
`L10n` loads Interface/Core tables
from the packaged resource bundle or SwiftPM's development bundle and formats
arguments using the selected locale. SwiftUI observes the shared LanguageSettings through L10n.ui and re-renders text
without recreating views, retaining unsaved forms and the AppModel/session; project content and server messages are not
translated. English is the fallback for unsupported languages or missing keys.

Slack is an optional second conversation source. `SlackChatModel` owns the
OAuth/Keychain session, account- and project-scoped channel bindings, channel
history and plain-text sends; `SlackClient` contains the injected Slack Web API
transport. The native PKCE flow uses `sprintwake-slack://oauth/callback`, user
scopes only, rotating refresh tokens and no Client Secret. Threads and files
open in Slack; the first release polls and does not implement DMs, reactions,
uploads or push notifications. Demo mode uses an in-memory Slack API and never
reads Keychain or sends network requests.

App updates use Sparkle 2.10.1, pinned through SwiftPM. `AppUpdateController` is
independent of GitHub/Slack authorization and project selection. The standard
Sparkle driver verifies signed feeds and Ed25519-signed archives before
extraction; the app adds a gentle download badge plus global menu/settings.
Automatic checks default on in official releases, automatic installation is
disabled, and system profile telemetry is disabled. `UpdateConfiguration` rejects
unsafe/missing feed/key metadata before starting Sparkle. Local builds/demo mode
do not start it. Explicit updater testing uses a separate bundle identity and
only loopback HTTP, while all GitHub/Slack data remains in the isolated demo.

Release metadata is in `Configuration/Release.json`. `scripts/release.sh` requires
a clean committed tree and the Sparkle key in Keychain. Its default community
path uses ad hoc app signing and Ed25519-signed feed/archive updates without a
paid Apple membership, as in Sprintwake Studios' local updater. macOS may require
manual approval on first installation. Explicit `--notarize` additionally
requires Developer ID signing and a notarization profile, and never silently
falls back to the community path. Both paths produce ZIP/appcast/checksum,
verify signatures/build metadata and pin a local release tag to the built commit.
Publishing remains a separate printed command. The owner's private update key
stays in Keychain; only its public key is versioned.

## Delivery decisions and continuation

The selected publication target is the public repository
`oddmundleikvoll/sprintwake-projects`. The owner chose community releases using
the existing Sparkle key, without paid Apple membership. Keep Developer ID and
notarization as an explicit optional path. The existing local development app
must receive its first public release build before it can receive public updates.

The bundled Slack registration currently serves the owner's authorized workspace;
general installation in other workspaces needs separate Slack distribution setup.
The source uses the MIT License; the owner delegated the license choice during
publication preparation. Public repository visibility and local update tests do
not complete distribution verification.

README leads with real screenshots of the fictional English Website launch demo
and installation instructions. `Documentation/Installation.md` covers GitHub and
optional Slack setup; README includes a copyable assistant prompt that leaves
authorization to the user and verifies connections without real writes. Public
screenshots must use a separately identified demo bundle with no real sessions.

`STATUS.md` starts with the current verified snapshot and keeps earlier evidence
under a historical record. `PLAN.md` is the ordered continuation plan, including
public-source review, licensing, Slack distribution, Git/CI setup, release signing,
publication and fresh-install/public-update verification. Consult those files for
mutable completion state rather than inferring it from earlier chat or test logs.


## Workspace appearance

`Sources/Fjord/WorkspaceStyle.swift` centralizes adaptive opaque canvas, sidebar,
column, card and border colors. Native appearance selects light or dark variants;
card borders strengthen for increased contrast. Workspace, board, sign-in and
conversation views share these surfaces. Styling does not alter the model,
network writes, selection persistence or draft/update protection. Keep hover
feedback instantaneous and preserve native keyboard/focus controls.
