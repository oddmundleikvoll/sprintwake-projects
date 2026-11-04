# Slack setup

Slack is an optional project conversation source. GitHub draft conversations
continue to work without Slack. Tokens are kept in macOS Keychain; access
tokens, refresh tokens and client secrets are never written to this repository,
UserDefaults or logs.

## Register the public Slack client

The bundled public Client ID belongs to **Sprintwake Projects** in the developer's
workspace and is currently workspace-limited. General distribution has not been
verified. For another workspace or your own fork, create a Slack app at
[api.slack.com/apps](https://api.slack.com/apps), choosing **Paste a manifest** and
`Configuration/SlackManifest.json`. Importing the manifest enables PKCE and token
rotation; verify both under **OAuth & Permissions**. PKCE marks a public client
and cannot be disabled without Slack support. The important values
are:

- Redirect URL: `sprintwake-slack://oauth/callback`
- User scopes: `channels:read`, `channels:history`, `users:read`, `chat:write`
- Optional private-channel scopes: `groups:read`, `groups:history`
- PKCE enabled and token rotation enabled

This is a native public client. It does not use a Client Secret. Keep the Client
ID public, but never add a secret to the repository or release build. Users of
the packaged app can enter their own public Client ID under **Slack app setup**
in Settings, without rebuilding. Fork owners can put the Client ID in
`Configuration/Slack.json`:

```json
{"clientID":"your_public_slack_client_id"}
```

For a local build, the environment override takes precedence. An empty value
omits the bundled value:

```sh
SPRINTWAKE_SLACK_CLIENT_ID=your_public_slack_client_id ./scripts/build-app.sh
```

The first connection opens Slack in the browser. An existing Slack browser
session may be reused, but the user must still approve the requested scopes.
The app verifies the returned workspace and user and stores the user and refresh
tokens under the active GitHub account's Keychain namespace. Rotating access
tokens are renewed before expiry. With PKCE, each refresh token expires after
30 days; a revoked or expired authorization requires a new connection. The app
can reuse an existing browser session, but cannot reuse the native Slack app's
stored credentials.

Before distributing the same Slack app to other workspaces, its owner must
complete Slack's **Manage Distribution** requirements. A public GitHub repository
does not make a workspace-only Slack registration installable everywhere.
Fork owners can register their own public client using the included manifest.

## Use Slack in the app

Choose Slack as the conversation source, select a channel, and refresh or load
older messages. The binding is local and scoped by GitHub account and project.
Switching accounts hides the previous account's Slack connection without
deleting it. **Disconnect Slack** deletes that account's local credential.

The app reads channel history and sends plain text as the connected Slack user.
Threads and files open in Slack. This first integration does not implement direct
messages, reactions, uploads, push notifications, or typing/read indicators.
The active project polls every 60 seconds while the app is active and supports manual refresh; Slack rate
limits are respected using the server's retry delay.

If Slack reports an ambiguous send result, Sprintwake keeps the composer text,
marks delivery for review, and does not retry automatically. Check the channel
in Slack before acknowledging the warning and sending again.

The isolated `--demo` build uses an in-memory Slack workspace. It never reads
Keychain credentials, contacts Slack, or writes to an external channel, and is
the safe place to exercise the UI.

The implementation follows Slack's current [PKCE guidance](https://docs.slack.dev/authentication/using-pkce/),
[OAuth access-token response](https://docs.slack.dev/reference/methods/oauth.v2.access/),
[conversation history](https://docs.slack.dev/reference/methods/conversations.history/),
and [message posting](https://docs.slack.dev/reference/methods/chat.postMessage/)
contracts. A live Slack registration and consent are required before claiming
live workspace validation; automated tests use injected transports and never
send real messages.
