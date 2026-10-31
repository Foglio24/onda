#!/usr/bin/env python3
"""Validate published IPAs and refresh the AltStore Classic listing."""
import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO = os.environ["GITHUB_REPOSITORY"]
BUNDLE = "com.onda.player"
BANNER = "https://raw.githubusercontent.com/Foglio24/onda/main/docs/images/seaglass-banner.jpg"


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def clean_notes(text):
    text = text.split("**Install:**", 1)[0]
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.M)
    text = text.replace("**", "").replace("`", "")
    return text.strip() or "Improvements and fixes."


def validate_ipa(release):
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("Only published stable releases are supported")
    assets = [a for a in release["assets"] if a["name"] == "Seaglass.ipa" and a["state"] == "uploaded"]
    if len(assets) != 1:
        raise ValueError("A unique uploaded Seaglass.ipa is required")
    asset = assets[0]
    url = asset["browser_download_url"]
    if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
        raise ValueError("Unexpected IPA download URL")
    with tempfile.TemporaryDirectory() as tmp:
        ipa = Path(tmp) / "app.ipa"
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--max-time", "180", "--output", str(ipa), url], check=True)
        if ipa.stat().st_size != asset["size"]:
            raise ValueError("IPA size does not match GitHub release")
        digest = asset.get("digest")
        if digest and (not digest.startswith("sha256:") or hashlib.sha256(ipa.read_bytes()).hexdigest() != digest[7:]):
            raise ValueError("IPA digest does not match GitHub release")
        with zipfile.ZipFile(ipa) as archive:
            names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
            if len(names) != 1:
                raise ValueError("IPA must contain one app Info.plist")
            info = plistlib.loads(archive.read(names[0]))
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    if info["CFBundleIdentifier"] != BUNDLE or release["tag_name"] != "v" + version:
        raise ValueError("IPA bundle identifier or version does not match release")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", build):
        raise ValueError("Invalid IPA version or build number")
    permissions = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription") and isinstance(v, str)}
    return {
        "version": version, "buildVersion": build, "date": release["published_at"],
        "localizedDescription": clean_notes(release.get("body") or ""),
        "downloadURL": url, "size": asset["size"],
        "minOSVersion": str(info.get("MinimumOSVersion", "26.0")),
    }, permissions


def main():
    source_path = Path("altstore-source.json")
    source = json.loads(source_path.read_text())
    app = source["apps"][0]
    if app["bundleIdentifier"] != BUNDLE:
        raise ValueError("Unexpected source bundle identifier")
    latest = gh(f"repos/{REPO}/releases/latest")
    entry, privacy = validate_ipa(latest)
    # Bootstrap a known, functioning prior Seaglass release, validated from its IPA.
    candidates = [entry]
    if not any(v["version"] == "1.20.0" for v in app["versions"]) and entry["version"] != "1.20.0":
        prior = gh(f"repos/{REPO}/releases/tags/v1.20.0")
        historical, _ = validate_ipa(prior)
        candidates.append(historical)
    existing = {v["version"]: v for v in app["versions"] if v["version"] not in {"1.18.1", "1.19.0"}}
    for version in candidates:
        existing[version["version"]] = version
    # AltStore uses the first compatible entry; do not trust publication dates for ordering.
    app["versions"] = sorted(existing.values(), key=lambda v: tuple(int(x) for x in v["version"].split(".")), reverse=True)
    if app["versions"][0]["version"] != entry["version"]:
        raise ValueError("Latest release would not be first; refusing to update source")
    app["appPermissions"]["privacy"] = privacy
    news_id = "release-" + entry["version"]
    if not any(item["identifier"] == news_id for item in source["news"]):
        source["news"].insert(0, {"title": "Seaglass " + entry["version"], "identifier": news_id,
            "caption": "A new Seaglass update is available. Tap to see what's new.",
            "date": entry["date"], "tintColor": "#EC3F8E", "imageURL": BANNER,
            "notify": False, "url": f"https://github.com/{REPO}/releases/tag/v{entry['version']}", "appID": BUNDLE})
    source_path.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    print("Validated IPA", entry["version"], "build", entry["buildVersion"])


if __name__ == "__main__":
    main()
