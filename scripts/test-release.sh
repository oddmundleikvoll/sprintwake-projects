#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/release_config.py --json >/dev/null
if SPRINTWAKE_UPDATE_FEED_URL="http://example.com/appcast.xml" python3 scripts/release_config.py --json >/dev/null 2>&1; then
  echo "unsafe HTTP override was accepted" >&2
  exit 1
fi
SPRINTWAKE_UPDATE_TESTING=1 SPRINTWAKE_UPDATE_FEED_URL="http://127.0.0.1:8080/appcast.xml" \
  python3 scripts/release_config.py --json >/dev/null
if SPRINTWAKE_UPDATE_TESTING=1 SPRINTWAKE_UPDATE_PUBLIC_KEY="not-base64" python3 scripts/release_config.py --json >/dev/null 2>&1; then
  echo "invalid public key was accepted" >&2
  exit 1
fi
python3 - <<'PY'
import base64
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import scripts.release_config as config

valid = {"version": "0.2.0", "build": 2, "repository": "owner/name", "sparklePublicKey": base64.b64encode(b"k" * 32).decode()}
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "Release.json"
    config.CONFIG_PATH = path
    for mutation in (
        {"build": 0},
        {"repository": "owner/../name"},
        {"repository": "owner/name?x"},
        {"sparklePublicKey": base64.b64encode(b"short").decode()},
    ):
        candidate = valid | mutation
        path.write_text(json.dumps(candidate))
        try:
            config.load(testing=False)
        except config.ReleaseConfigError:
            pass
        else:
            raise SystemExit(f"invalid release config accepted: {mutation}")
    path.write_text(json.dumps(valid))
    os.environ["SPRINTWAKE_UPDATE_FEED_URL"] = "https://user:pass@example.com/appcast.xml"
    try:
        config.load(testing=False)
    except config.ReleaseConfigError:
        pass
    else:
        raise SystemExit("feed URL credentials accepted")
    for unsafe in ["https://user:pass@example.com/appcast.xml", "https:///missing", "https://example.com:invalid/feed", "https://example.com/feed?q=1", "https://example.com/feed#frag", "http://example.com/feed"]:
        try:
            config._feed(unsafe, True, "owner/name")
        except config.ReleaseConfigError:
            pass
        else:
            raise SystemExit("unsafe feed accepted")
    fingerprint = "A" * 40
    identities = f'  1) {fingerprint} "Developer ID Application: Example (TEAM)"\n  1 valid identities found'
    assert config.developer_identity("Developer ID Application: Example (TEAM)", identities) == fingerprint
    assert config.developer_identity(fingerprint, identities) == fingerprint
    try:
        config.developer_identity("Unknown", identities)
    except config.ReleaseConfigError:
        pass
    else:
        raise SystemExit("unknown signing identity accepted")
    os.environ.pop("SPRINTWAKE_UPDATE_FEED_URL", None)
    os.environ.pop("SPRINTWAKE_UPDATE_PUBLIC_KEY", None)
    os.environ["SPRINTWAKE_RELEASE_BUILD"] = "1"
    os.environ["SPRINTWAKE_NOTARIZE"] = "0"
    community = config.load(testing=False)
    assert community["updatesEnabled"] and not community["notarize"]
    path.write_text(json.dumps(valid | {"sparklePublicKey": ""}))
    try:
        config.load(testing=False)
    except config.ReleaseConfigError:
        pass
    else:
        raise SystemExit("community release accepted a missing update key")
    path.write_text(json.dumps(valid))
    os.environ["SPRINTWAKE_NOTARIZE"] = "1"
    assert config.load(testing=False)["notarize"]
    for release, testing in [("0", False), ("1", True)]:
        os.environ["SPRINTWAKE_RELEASE_BUILD"] = release
        try:
            config.load(testing=testing)
        except config.ReleaseConfigError:
            pass
        else:
            raise SystemExit("notarization accepted outside a production release")
    os.environ["SPRINTWAKE_RELEASE_BUILD"] = "0"
    os.environ["SPRINTWAKE_NOTARIZE"] = "0"

    # Exercise the real release preflight in a clean disposable repository.
    # Community releases must reach Sparkle setup without Apple credentials;
    # --notarize must still fail closed when no Developer ID is available.
    checkout = Path(directory) / "checkout"
    (checkout / "scripts").mkdir(parents=True)
    (checkout / "Configuration").mkdir()
    for script in ["release.sh", "release_config.py"]:
        shutil.copy2(Path("scripts") / script, checkout / "scripts" / script)
    (checkout / "Configuration/Release.json").write_text(json.dumps(valid))
    fake_tools = Path(directory) / "tools"
    fake_tools.mkdir()
    audit = Path(directory) / "apple-tool-calls"
    for tool in ["security", "xcrun"]:
        stub = fake_tools / tool
        stub.write_text('#!/bin/sh\nprintf "%s\\n" invoked >> "$SPRINTWAKE_PREFLIGHT_AUDIT"\nexit 0\n')
        stub.chmod(0o755)
    environment = dict(os.environ, PATH=f"{fake_tools}:{os.environ['PATH']}",
        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
        SPARKLE_TOOLS_DIR=str(Path(directory) / "missing-sparkle-tools"),
        SPRINTWAKE_PREFLIGHT_AUDIT=str(audit))
    for name in ["FJORD_SIGN_IDENTITY", "SPRINTWAKE_NOTARY_PROFILE", "SPRINTWAKE_UPDATE_TESTING"]:
        environment.pop(name, None)
    for args in [["init", "-q"], ["add", "."],
            ["-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
             "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"]]:
        subprocess.run(["git", *args], cwd=checkout, env=environment, check=True, capture_output=True)
    result = subprocess.run(["./scripts/release.sh"], cwd=checkout, env=environment, capture_output=True, text=True)
    assert result.returncode == 2 and "Missing Sparkle tools" in result.stderr, result.stderr
    assert not audit.exists(), "community preflight invoked Apple signing/notary tools"
    result = subprocess.run(["./scripts/release.sh", "--notarize"], cwd=checkout, env=environment, capture_output=True, text=True)
    assert result.returncode == 2 and "valid installed Developer ID" in result.stderr, result.stderr
    assert audit.read_text().splitlines() == ["invoked"]
    archive = Path(directory) / "archive.zip"
    archive.write_bytes(b"test archive")
    appcast = Path(directory) / "appcast.xml"
    signature = base64.b64encode(b"s" * 64).decode()
    def feed(build="2", version="0.2.0", length=12):
        return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString><enclosure url="https://example.com/app.zip" sparkle:edSignature="{signature}" length="{length}"/></item></channel></rss>'
    appcast.write_text(feed())
    config.validate_appcast(appcast, "0.2.0", 2, "https://example.com/app.zip", archive)
    for invalid in [feed(build="3"), feed(version="0.2.1"), feed(length=11), feed().replace(signature, "bad")]:
        appcast.write_text(invalid)
        try:
            config.validate_appcast(appcast, "0.2.0", 2, "https://example.com/app.zip", archive)
        except config.ReleaseConfigError:
            pass
        else:
            raise SystemExit("invalid appcast accepted")
PY
if SPRINTWAKE_UPDATE_TESTING=1 ./scripts/release.sh >/dev/null 2>&1; then
  echo "release script accepted testing mode" >&2
  exit 1
fi
if ! bash -n scripts/build-app.sh scripts/release.sh; then
  exit 1
fi
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sprintwake-signature-test.XXXXXX")"
trap 'rm -rf "$VERIFY_ROOT"' EXIT
cat > "$VERIFY_ROOT/fixture.swift" <<'SWIFT'
import Foundation
import CryptoKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let data = Data("isolated update fixture".utf8)
try data.write(to: directory.appendingPathComponent("archive"))
try key.publicKey.rawRepresentation.base64EncodedString().write(to: directory.appendingPathComponent("public"), atomically: true, encoding: .utf8)
try key.signature(for: data).base64EncodedString().write(to: directory.appendingPathComponent("signature"), atomically: true, encoding: .utf8)
SWIFT
swift "$VERIFY_ROOT/fixture.swift" "$VERIFY_ROOT"
swiftc scripts/verify-update.swift -o "$VERIFY_ROOT/verify-update"
"$VERIFY_ROOT/verify-update" "$(cat "$VERIFY_ROOT/public")" "$(cat "$VERIFY_ROOT/signature")" "$VERIFY_ROOT/archive" >/dev/null
echo corruption >> "$VERIFY_ROOT/archive"
if "$VERIFY_ROOT/verify-update" "$(cat "$VERIFY_ROOT/public")" "$(cat "$VERIFY_ROOT/signature")" "$VERIFY_ROOT/archive" >/dev/null 2>&1; then
  echo "modified archive passed signature verification" >&2
  exit 1
fi
echo "release configuration tests passed"
