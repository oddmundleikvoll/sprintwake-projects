#!/usr/bin/env python3
"""Validate Sprintwake release metadata and derive updater settings.

This module deliberately has no network or signing side effects.  It is used by
the app packager and by release.sh so that both paths apply the same checks.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "Configuration" / "Release.json"
VERSION_RE = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$")


class ReleaseConfigError(ValueError):
    pass


def developer_identity(requested: str, identities: str | None = None) -> str:
    if identities is None:
        identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                                    check=True, capture_output=True, text=True).stdout
    for line in identities.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(Developer ID Application:[^"]+)"\s*', line)
        if match and requested in (match[1], match[2]):
            return match[1]
    raise ReleaseConfigError("FJORD_SIGN_IDENTITY must be a valid installed Developer ID Application identity")


def _public_key(value: str) -> str:
    if not value:
        return ""
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ReleaseConfigError("sparklePublicKey must be valid base64") from exc
    if len(raw) != 32:
        raise ReleaseConfigError("sparklePublicKey must decode to 32 bytes")
    return value


def _feed(url: str, testing: bool, repository: str) -> str:
    if not url:
        url = f"https://github.com/{repository}/releases/latest/download/appcast.xml"
    parsed = urlparse(url)
    if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ReleaseConfigError("update feed must have a host and no credentials, query, or fragment")
    try:
        parsed.port
    except ValueError as exc:
        raise ReleaseConfigError("update feed has an invalid port") from exc
    if parsed.scheme == "https":
        return url
    loopback = parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if testing and loopback:
        return url
    raise ReleaseConfigError("update feed must use HTTPS (HTTP is only allowed for loopback testing)")


def validate_appcast(path: Path, version: str, build: int, asset_url: str, archive: Path | None = None) -> None:
    try:
        root = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError) as exc:
        raise ReleaseConfigError(f"invalid appcast: {exc}") from exc
    found = False
    for item in root.iter():
        if item.tag.rsplit("}", 1)[-1] != "item":
            continue
        values = {child.tag.rsplit("}", 1)[-1]: child for child in item}
        enclosure = values.get("enclosure")
        if enclosure is None:
            continue
        attrs = enclosure.attrib
        if attrs.get("url") != asset_url:
            continue
        signature = attrs.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")
        try:
            if len(base64.b64decode(signature, validate=True)) != 64:
                raise ValueError()
            length = int(attrs.get("length", "0"))
            if length <= 0 or (archive is not None and length != archive.stat().st_size):
                raise ValueError()
        except (ValueError, OSError) as exc:
            raise ReleaseConfigError("appcast asset has an invalid signature or length") from exc
        if values.get("version", values.get("sparkle:version")) is None:
            raise ReleaseConfigError("appcast asset has no version")
        item_version = values.get("shortVersionString")
        if item_version is None or (item_version.text or "") != version:
            raise ReleaseConfigError("appcast version does not match Release.json")
        version_text = values.get("version")
        if version_text is None:
            version_text = values.get("sparkle:version")
        if version_text is not None and (version_text.text or "") != str(build):
            raise ReleaseConfigError("appcast build does not match Release.json")
        found = True
    if not found:
        raise ReleaseConfigError("appcast has no signed item for the expected GitHub asset")


def load(*, testing: bool | None = None, require_release_key: bool = False) -> dict:
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReleaseConfigError(f"cannot read {CONFIG_PATH}: {exc}") from exc
    version = data.get("version")
    build = data.get("build")
    repository = data.get("repository")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version) or version == "0.0.0":
        raise ReleaseConfigError("version must be a positive semantic version")
    if not isinstance(build, int) or isinstance(build, bool) or build <= 0:
        raise ReleaseConfigError("build must be a positive integer")
    if not isinstance(repository, str) or not REPOSITORY_RE.fullmatch(repository):
        raise ReleaseConfigError("repository must be in owner/name form")
    configured_key = data.get("sparklePublicKey", "")
    if not isinstance(configured_key, str):
        raise ReleaseConfigError("sparklePublicKey must be a string")
    configured_key = _public_key(configured_key.strip())

    testing = (os.environ.get("SPRINTWAKE_UPDATE_TESTING") == "1") if testing is None else testing
    env_feed = os.environ.get("SPRINTWAKE_UPDATE_FEED_URL", "").strip()
    env_key = os.environ.get("SPRINTWAKE_UPDATE_PUBLIC_KEY", "").strip()
    if (env_feed or env_key) and not testing:
        raise ReleaseConfigError("update feed/key overrides require SPRINTWAKE_UPDATE_TESTING=1")
    public_key = _public_key(env_key) if env_key else configured_key
    feed = _feed(env_feed, testing, repository)
    release_build = os.environ.get("SPRINTWAKE_RELEASE_BUILD") == "1"
    notarize = os.environ.get("SPRINTWAKE_NOTARIZE") == "1"
    if notarize and (not release_build or testing):
        raise ReleaseConfigError("notarization requires a production release build without testing overrides")
    if (require_release_key or release_build) and not public_key:
        raise ReleaseConfigError("a production release requires sparklePublicKey")
    return {
        "version": version,
        "build": build,
        "repository": repository,
        "sparklePublicKey": public_key,
        "feedURL": feed,
        "updatesEnabled": release_build,
        "updateTesting": testing,
        "notarize": notarize,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print validated settings as JSON")
    parser.add_argument("--require-release-key", action="store_true")
    parser.add_argument("--validate-appcast", metavar="PATH")
    parser.add_argument("--asset-url")
    parser.add_argument("--archive", metavar="PATH")
    parser.add_argument("--developer-id", metavar="NAME_OR_SHA1")
    args = parser.parse_args()
    try:
        if args.developer_id is not None:
            print(developer_identity(args.developer_id))
            return 0
        result = load(require_release_key=args.require_release_key)
        if args.validate_appcast:
            if not args.asset_url:
                raise ReleaseConfigError("--asset-url is required with --validate-appcast")
            validate_appcast(Path(args.validate_appcast), result["version"], result["build"], args.asset_url,
                             Path(args.archive) if args.archive else None)
    except ReleaseConfigError as exc:
        print(f"release config: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
