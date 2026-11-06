#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION=release
if [[ "${1:-}" == "--debug" ]]; then
  CONFIGURATION=debug
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--debug]" >&2
  exit 2
fi

cd "$TASK_ROOT"
CONFIG_ARGS=(--json)
if [[ "${SPRINTWAKE_RELEASE_BUILD:-0}" == "1" && "${SPRINTWAKE_UPDATE_TESTING:-0}" != "1" ]]; then
  CONFIG_ARGS+=(--require-release-key)
fi
RELEASE_CONFIG_JSON="$(python3 scripts/release_config.py "${CONFIG_ARGS[@]}")"
NOTARIZE="$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["notarize"]))' <<<"$RELEASE_CONFIG_JSON")"
SIGN_IDENTITY="${FJORD_SIGN_IDENTITY:--}"
if [[ "$NOTARIZE" == "1" ]]; then
  SIGN_IDENTITY="$(python3 scripts/release_config.py --developer-id "$SIGN_IDENTITY")"
fi
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_PATH="${SPRINTWAKE_APP_PATH:-$TASK_ROOT/dist/Sprintwake Projects.app}"
if pgrep -f -- "$APP_PATH/Contents/MacOS/Sprintwake" >/dev/null 2>&1; then
  echo "The app is running at $APP_PATH; set SPRINTWAKE_APP_PATH to an alternate output." >&2
  exit 1
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/Fjord" "$APP_PATH/Contents/MacOS/Sprintwake"
# SwiftPM's Bundle.module locates this companion bundle inside Contents/Resources.
RESOURCE_BUNDLE="$BIN_PATH/Fjord_FjordCore.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing localization resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
rm -rf "$APP_PATH/Contents/Resources/Fjord_FjordCore.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"

python3 - "$APP_PATH/Contents/Info.plist" "$RELEASE_CONFIG_JSON" <<'PY'
import os
import json
import plistlib
import sys
from pathlib import Path

info = {
    "CFBundleName": "Sprintwake Projects",
    "CFBundleDisplayName": "Sprintwake Projects",
    # Keep the established identity so preferences and Keychain access survive rebranding.
    "CFBundleIdentifier": "no.oddmund.Fjord",
    "CFBundleExecutable": "Sprintwake",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.2.0",
    "CFBundleVersion": "2",
    "CFBundleIconFile": "Sprintwake",
    "LSMinimumSystemVersion": "14.0",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleLocalizations": ["en", "nb"],
    "UTExportedTypeDeclarations": [
        {"UTTypeIdentifier": "no.oddmund.Fjord.board-item", "UTTypeConformsTo": ["public.data"],
         "UTTypeDescription": "Sprintwake board item"},
        {"UTTypeIdentifier": "no.oddmund.Fjord.board-column", "UTTypeConformsTo": ["public.data"],
         "UTTypeDescription": "Sprintwake board column"},
    ],
    "CFBundleURLTypes": [{
        "CFBundleURLName": "Sprintwake Slack sign-in",
        "CFBundleURLSchemes": ["sprintwake-slack"],
        "CFBundleTypeRole": "Viewer",
    }],
    "NSHighResolutionCapable": True,
    "NSHumanReadableCopyright": "Sprintwake Projects · GitHub Projects for Mac",
}
release = json.loads(sys.argv[2])
info["CFBundleShortVersionString"] = release["version"]
info["CFBundleVersion"] = str(release["build"])
updates_testing = release["updateTesting"]
updates_enabled = release["updatesEnabled"] or updates_testing
feed = release["feedURL"]
public_key = release["sparklePublicKey"]
info.update({
    "SprintwakeUpdatesEnabled": updates_enabled,
    "SprintwakeUpdateTesting": updates_testing,
    "SUFeedURL": feed,
    "SUPublicEDKey": public_key,
    "SUEnableAutomaticChecks": True,
    "SUAutomaticallyUpdate": False,
    "SUAllowsAutomaticUpdates": False,
    "SUSendProfileInfo": False,
    "SUShowReleaseNotes": False,
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
})
if updates_testing:
    info["CFBundleIdentifier"] = "no.oddmund.Sprintwake.UpdateTest.Local"
    info["FjordDemoMode"] = True
    info.pop("CFBundleURLTypes", None)
    info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True}
# Client ID is public. Keep private credentials out of this file and the bundle.
configuration_path = Path("Configuration/GitHub.json")
configuration = json.loads(configuration_path.read_text()) if configuration_path.exists() else {}
client_id = os.environ.get("FJORD_GITHUB_CLIENT_ID", configuration.get("clientID", "")).strip()
if client_id:
    info["GitHubOAuthClientID"] = client_id
slack_path = Path("Configuration/Slack.json")
slack_configuration = json.loads(slack_path.read_text()) if slack_path.exists() else {}
slack_client_id = os.environ.get("SPRINTWAKE_SLACK_CLIENT_ID", slack_configuration.get("clientID", "")).strip()
if slack_client_id:
    info["SlackOAuthClientID"] = slack_client_id
with open(sys.argv[1], "wb") as output:
    plistlib.dump(info, output)
PY

ICONSET="$TASK_ROOT/.build/Sprintwake.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$TASK_ROOT/.build/Sprintwake-icon.png"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$TASK_ROOT/.build/Sprintwake-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$TASK_ROOT/.build/Sprintwake-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/Sprintwake.icns"

# SwiftPM places Sparkle's binary target in the artifacts directory. Preserve
# its framework symlinks while embedding it in the standard app location.
SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORK_PATH:-}"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  SPARKLE_FRAMEWORK="$(find "$TASK_ROOT/.build/artifacts" -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
fi
if [[ -n "$SPARKLE_FRAMEWORK" && -d "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP_PATH/Contents/Frameworks"
  rm -rf "$APP_PATH/Contents/Frameworks/Sparkle.framework"
  ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
else
  echo "Sparkle.framework was not found in the SwiftPM artifacts." >&2
  exit 1
fi
# Keep the project and dependency notices with the distributed application.
cp "$TASK_ROOT/LICENSE" "$APP_PATH/Contents/Resources/Sprintwake-LICENSE"
cp "$TASK_ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE"

if [[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
  # Sign nested Sparkle code before the app. Community releases use ad hoc
  # signatures; --notarize additionally requires a Developer ID identity.
  SIGN_TIMESTAMP=(--timestamp=none)
  if [[ "$NOTARIZE" == "1" ]]; then
    SIGN_TIMESTAMP=(--options runtime --timestamp)
  fi
  # Autoupdate is the only standalone Mach-O; bundle executables are signed
  # through their enclosing bundles, never modified after a bundle is sealed.
  codesign --force --sign "$SIGN_IDENTITY" "${SIGN_TIMESTAMP[@]}" "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  while IFS= read -r nested; do
    codesign --force --sign "$SIGN_IDENTITY" "${SIGN_TIMESTAMP[@]}" "$nested"
  done < <(find "$APP_PATH/Contents/Frameworks/Sparkle.framework" -depth -type d \( -name '*.xpc' -o -name '*.app' \) -print)
  codesign --force --sign "$SIGN_IDENTITY" "${SIGN_TIMESTAMP[@]}" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
fi
APP_IDENTIFIER=no.oddmund.Fjord
if [[ "${SPRINTWAKE_UPDATE_TESTING:-0}" == "1" ]]; then APP_IDENTIFIER=no.oddmund.Sprintwake.UpdateTest.Local; fi
APP_SIGN_FLAGS=(--identifier "$APP_IDENTIFIER")
if [[ "$NOTARIZE" == "1" ]]; then APP_SIGN_FLAGS+=(--options runtime --timestamp); else APP_SIGN_FLAGS+=(--timestamp=none); fi
codesign --force --sign "$SIGN_IDENTITY" "${APP_SIGN_FLAGS[@]}" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
if [[ "$NOTARIZE" == "1" ]]; then
  codesign --verify --strict -R 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP_PATH"
fi
echo "Built $APP_PATH"
