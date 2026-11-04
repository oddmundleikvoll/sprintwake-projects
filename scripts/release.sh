#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: ./scripts/release.sh [--notarize]

Prepares an ad hoc-signed community release with Ed25519-signed Sparkle
updates. No Apple Developer membership is needed. Requires clean committed
source and the update signing key in Keychain. Nothing is uploaded.

--notarize additionally requires FJORD_SIGN_IDENTITY (Developer ID Application)
and SPRINTWAKE_NOTARY_PROFILE; it notarizes and staples the app with Apple.
HELP
  exit 0
fi
NOTARIZE=0
if [[ $# -eq 1 && "$1" == "--notarize" ]]; then
  NOTARIZE=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--notarize | --help]" >&2
  exit 2
fi

export SPRINTWAKE_RELEASE_BUILD=1
export SPRINTWAKE_NOTARIZE="$NOTARIZE"
if [[ "${SPRINTWAKE_UPDATE_TESTING:-0}" == "1" || -n "${SPRINTWAKE_UPDATE_FEED_URL:-}" || -n "${SPRINTWAKE_UPDATE_PUBLIC_KEY:-}" ]]; then
  echo "Release builds cannot use updater testing or feed/key overrides." >&2
  exit 2
fi
RELEASE_COMMIT="$(git rev-parse --verify HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit the intended release changes before preparing a release." >&2
  exit 2
fi
CONFIG_JSON="$(python3 scripts/release_config.py --json --require-release-key)"
read -r VERSION BUILD REPOSITORY <<<"$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["version"], d["build"], d["repository"])' <<<"$CONFIG_JSON")"
if [[ "$NOTARIZE" == "1" ]]; then
  SIGN_IDENTITY="$(python3 scripts/release_config.py --developer-id "${FJORD_SIGN_IDENTITY:-}")"
  export FJORD_SIGN_IDENTITY="$SIGN_IDENTITY"
  if [[ -z "${SPRINTWAKE_NOTARY_PROFILE:-}" ]]; then
    echo "SPRINTWAKE_NOTARY_PROFILE is required with --notarize." >&2
    exit 2
  fi
else
  # Community releases authenticate updates with Ed25519, independently of
  # Apple's paid code signing/notarization service.
  export FJORD_SIGN_IDENTITY=-
fi
TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT/.build/sparkle-tools}"
if [[ ! -d "$TOOLS_DIR" && -d "$ROOT/.build/artifacts/sparkle/Sparkle/bin" ]]; then
  TOOLS_DIR="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
fi
APPCAST_TOOL="$TOOLS_DIR/generate_appcast"
SIGN_TOOL="$TOOLS_DIR/sign_update"
if [[ ! -x "$APPCAST_TOOL" || ! -x "$SIGN_TOOL" ]]; then
  echo "Missing Sparkle tools in $TOOLS_DIR (generate_appcast and sign_update)." >&2
  exit 2
fi
if [[ "$NOTARIZE" == "1" ]]; then
  if ! xcrun notarytool history --keychain-profile "$SPRINTWAKE_NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    echo "SPRINTWAKE_NOTARY_PROFILE is not available to notarytool." >&2
    exit 2
  fi
fi
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sprintwake-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
swiftc "$ROOT/scripts/verify-update.swift" -o "$VERIFY_DIR/verify-update"

"$ROOT/scripts/build-app.sh"
APP_PATH="${SPRINTWAKE_APP_PATH:-$ROOT/dist/Sprintwake Projects.app}"
[[ -d "$APP_PATH" ]] || { echo "Missing app: $APP_PATH" >&2; exit 1; }
ARTIFACT_DIR="$ROOT/dist/release/$VERSION"
mkdir -p "$ARTIFACT_DIR"
ARCHIVE="$ARTIFACT_DIR/Sprintwake-Projects-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE"
if [[ "$NOTARIZE" == "1" ]]; then
  # Only the profile name is passed, never its secret. Repack after stapling.
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$SPRINTWAKE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  rm -f "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE"
fi

KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-Sprintwake Projects Updates}"
# generate_appcast reads the private EdDSA key from the user's Keychain.  The
# account name is passed as an argument; no private material is printed.
"$APPCAST_TOOL" --account "$KEYCHAIN_ACCOUNT" --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" "$ARTIFACT_DIR" \
  >"$ARTIFACT_DIR/generate-appcast.log"
rm -f "$ARTIFACT_DIR/generate-appcast.log"
APPCAST="$ARTIFACT_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || { echo "Sparkle did not produce $APPCAST" >&2; exit 1; }
ASSET_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/Sprintwake-Projects-$VERSION.zip"
python3 scripts/release_config.py --validate-appcast "$APPCAST" --asset-url "$ASSET_URL" --archive "$ARCHIVE"
SIGNATURE="$(python3 - "$APPCAST" "$ASSET_URL" <<'PY'
import sys
from xml.etree import ElementTree
root = ElementTree.parse(sys.argv[1]).getroot()
for item in root.iter():
    if item.tag.rsplit("}", 1)[-1] != "item":
        continue
    for child in item:
        if child.tag.rsplit("}", 1)[-1] == "enclosure" and child.attrib.get("url") == sys.argv[2]:
            for key, value in child.attrib.items():
                if key.rsplit("}", 1)[-1] == "edSignature":
                    print(value)
                    raise SystemExit
raise SystemExit("missing appcast signature")
PY
)"
"$VERIFY_DIR/verify-update" "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sparklePublicKey"])' <<<"$CONFIG_JSON")" "$SIGNATURE" "$ARCHIVE"
"$SIGN_TOOL" --account "$KEYCHAIN_ACCOUNT" --verify "$APPCAST"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
if [[ "$(git rev-parse HEAD)" != "$RELEASE_COMMIT" || -n "$(git status --porcelain)" ]]; then
  echo "The source changed during release preparation; rebuild from the intended clean commit." >&2
  exit 2
fi
if git show-ref --verify --quiet "refs/tags/v$VERSION"; then
  [[ "$(git rev-parse "v$VERSION^{commit}")" == "$RELEASE_COMMIT" ]] || { echo "Release tag points to another commit." >&2; exit 2; }
else
  git tag -a "v$VERSION" "$RELEASE_COMMIT" -m "Sprintwake Projects $VERSION"
fi
echo "Prepared $ARCHIVE"
echo "Prepared $APPCAST"
if [[ "$NOTARIZE" == "1" ]]; then
  echo "Developer ID signed and notarized; Sparkle feed and archive signatures verified."
else
  echo "Community release: ad hoc signed, not notarized; Sparkle feed and archive signatures verified."
  echo "macOS may require manual approval on first installation."
fi
echo "No GitHub release was created. After reviewing the appcast, run:"
python3 - "$VERSION" "$REPOSITORY" "$ARCHIVE" "$ARCHIVE.sha256" "$APPCAST" "$RELEASE_COMMIT" <<'PY'
import shlex
import sys
version, repository, archive, checksum, appcast, commit = sys.argv[1:]
push = ["git", "push", f"https://github.com/{repository}.git", f"refs/tags/v{version}"]
release = ["gh", "release", "create", f"v{version}", "--repo", repository, "--verify-tag", "--target", commit,
    "--title", f"Sprintwake Projects {version}", archive, checksum, appcast]
print(shlex.join(push) + " && " + shlex.join(release))
PY
