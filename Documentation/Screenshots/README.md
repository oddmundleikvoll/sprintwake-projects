# README screenshots

These are native window captures of Sprintwake Projects using fictional data:

- `board.jpg`: Website launch board, including GitHub draft conversations.
- `list.jpg`: the same example tasks in list view.
- `slack.jpg`: the in-memory Sprintwake Demo workspace and #project channel.

The project, repositories, people and messages are example data from
`DemoProjectsAPI` and `DemoSlackAPI`. No real project/account/channel was opened
to make these images. The captures come from a separately identified app bundle
(`no.oddmund.Sprintwake.PublicationDemo`) with `FjordDemoMode=true`, copied outside
the checkout with its localization bundle. It starts in English even on a
Norwegian Mac, never restores real sessions, and never starts public updates.

For replacement screenshots, build to a separate `SPRINTWAKE_APP_PATH`, assign a
unique demo bundle identifier and `FjordDemoMode=true`, remove the Slack callback
registration and re-sign the modified bundle. Capture only that app's window.
Verify the local-demo banner and fictional project/channel before saving any
image here. Do not publish live-account screenshots or unrelated desktop windows.
