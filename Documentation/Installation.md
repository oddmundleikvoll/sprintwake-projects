# Install and connect

Sprintwake Projects needs macOS 14 or later. New installations use English;
choose Norwegian Bokmål or System language in **Sprintwake Projects → Settings**
if desired. GitHub and Slack content keeps its original language.

## Install the app

The first binary release is being prepared. Until it is published, use the
source instructions below. Published packages will be available on
[GitHub Releases](https://github.com/oddmundleikvoll/sprintwake-projects/releases).
The initial package targets Apple Silicon (arm64). Intel/universal packages
have not been qualified. Check **Apple menu → About This Mac** for your processor.

1. Download the release's `Sprintwake-Projects-<version>.zip` app archive.
2. Unzip it and drag **Sprintwake Projects.app** into **Applications**. Quit an
   existing copy before replacing it.
3. Open the app. Community releases use an ad hoc signature and are not Apple
   notarized. If macOS blocks first launch, follow
   [Apple's instructions](https://support.apple.com/en-us/102445). If you trust
   the download, **System Settings → Privacy & Security → Open Anyway** lets you
   approve this app. Keep Gatekeeper and quarantine protections enabled.

Official release builds use signed Sparkle updates. Local source builds have
public update checks disabled. See [Updates.md](Updates.md) for how they differ.

### Build from source

Install Git, Swift 6 and the macOS SDK using Xcode or Xcode Command Line Tools.
Then run:

```sh
git clone https://github.com/oddmundleikvoll/sprintwake-projects.git
cd sprintwake-projects
./scripts/test.sh
./scripts/build-app.sh
open "dist/Sprintwake Projects.app"
```

The package builds for the Mac's architecture and embeds its localization
resources and Sparkle framework. You can drag the built app from `dist` into
Applications. Build to another path with `SPRINTWAKE_APP_PATH` if an existing
copy is running; packaging refuses to overwrite a running app.

For an account-free preview, choose **Explore a local demo** at sign-in, or run:

```sh
open "dist/Sprintwake Projects.app" --args --demo
```

The example board and Slack workspace are in memory. Demo mode does not restore
real credentials or contact GitHub, Slack or update servers. Changes disappear
when the demo restarts.

## Connect GitHub

1. Choose **Sign in with GitHub**. The public OAuth Client ID is already bundled;
   you do not need your own OAuth registration for the standard app.
2. Open the displayed verification page and enter the code there yourself.
   GitHub still displays **Fjord Projects**, the existing OAuth registration.
3. Review and approve access. The default scopes are `read:user read:org project
   public_repo`. Private issues/PRs need `repo` in place of `public_repo`; that
   also grants access to private source code. Organizations can require approval
   or SSO. See [GitHub's authorization guide](https://docs.github.com/en/apps/oauth-apps/using-oauth-apps/authorizing-oauth-apps).
4. Choose the personal or organization project in the sidebar, or open a GitHub
   Projects URL. Some shared boards need a project link once; automatic discovery
   cannot find every standalone shared board.
5. If cards are hidden, choose **Grant access …** and review the same-account
   reauthorization flow. Project access and repository access are separate.

Tokens are kept in macOS Keychain. Never share access tokens, refresh tokens,
device codes or Keychain passwords with an assistant. Enter passwords only in
the system dialog. Verify setup by reading the board; no test task is required.

For a fork, register an OAuth app with Device Flow enabled and use its public
Client ID. The [README](../README.md#connect-to-github) documents build overrides.
Never embed a Client Secret.

## Connect Slack (optional)

GitHub draft conversations work without Slack. **The bundled Slack registration
is currently limited to the developer's workspace; general distribution has not
been verified.** Other workspaces can register their own client without rebuilding:

1. At [Slack app settings](https://api.slack.com/apps), create an app from
   [the included manifest](../Configuration/SlackManifest.json) in your workspace.
   Verify PKCE, token rotation and redirect `sprintwake-slack://oauth/callback`.
   Use user scopes; this native flow uses no Client Secret. PKCE marks a public
   client and cannot be disabled without Slack support.
2. In Sprintwake's Settings, open **Slack app setup** and enter its public
   **Client ID**. This is the only Slack app identifier the native client needs.
3. Choose **Connect Slack**. Approve the workspace and requested scopes yourself
   in Slack. Your administrator may need to approve installation.
4. Select **Slack** as the conversation source and choose a channel. You can also
   use **Project → Slack channel …** from the toolbar. The channel
   binding is saved locally per GitHub account and project.
5. Verify history loads. No test message is necessary. Join a channel in Slack
   before sending if you are not already a member.

See [Slack setup](Slack-setup.md) for scopes, refresh-token expiry, distribution
limits and troubleshooting. The native flow follows
[Slack's PKCE guidance](https://docs.slack.dev/authentication/using-pkce/);
workspace-only apps need separate [distribution setup](https://docs.slack.dev/app-management/distribution/)
before other workspaces can install them.

## If setup fails

- **No downloadable release:** build from source; do not use a source-code ZIP
  as an app package.
- **Wrong processor or older macOS:** check the release requirements. The initial
  binary is arm64/macOS 14+; other packages are not qualified.
- **GitHub authorization denied:** check the account, requested scopes, organization
  approval and SSO. Keep the working session during a failed reauthorization.
- **Slack installation blocked:** use your workspace's own client and check with
  its administrator. A public source repository does not enable Slack distribution.
- **Slack delivery uncertain:** check the channel in Slack before sending again.
  The app keeps the unsent text and does not retry automatically.

The [README](../README.md#ask-an-llm-to-help-with-setup) includes a copyable assistant
prompt for this flow. Fresh installation on another Mac and a subsequent public
Sparkle update still need separate verification; see [STATUS.md](../STATUS.md).
