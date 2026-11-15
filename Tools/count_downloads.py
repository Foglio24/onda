#!/usr/bin/env python3
"""Build a Shields endpoint badge from paginated GitHub release API responses.

It counts every download of the app itself, whatever the platform: the iPhone and iPad IPA
(Onda.ipa, Seaglass.ipa), the Mac app (Seaglass-mac.zip / Seaglass-mac.dmg) and the Android APKs
(Seaglass-x.y.z.apk, Seaglass-x.y.z-32bit.apk). Debug symbols and other files are left out.
"""

import json
import sys

APP_EXTENSIONS = (".ipa", ".apk", "-mac.zip", "-mac.dmg")
# App downloads of the iPhone/Mac releases v1.0.0 to v1.29.1, deleted on 2026-11-10 (they unlocked
# Seaglass Premium's features for free), counted from the deleting workflow's log.
ARCHIVED_DOWNLOADS = 170


def is_app(name):
    return name.lower().endswith(APP_EXTENSIONS)


def count_downloads(pages):
    if not isinstance(pages, list):
        raise ValueError("Expected a list of GitHub API pages")
    total = ARCHIVED_DOWNLOADS
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("Each GitHub API page must contain a list of releases")
        for release in page:
            if not isinstance(release, dict) or not isinstance(release.get("draft"), bool):
                raise ValueError("Invalid release: missing draft status")
            if release["draft"]:
                continue
            assets = release.get("assets")
            if not isinstance(assets, list):
                raise ValueError("Invalid release: missing assets")
            for asset in assets:
                if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
                    raise ValueError("Invalid release asset")
                if is_app(asset["name"]):
                    downloads = asset.get("download_count")
                    if isinstance(downloads, bool) or not isinstance(downloads, int) or downloads < 0:
                        raise ValueError("Invalid download count")
                    total += downloads
    return total


def badge(pages):
    return {
        "schemaVersion": 1,
        "label": "download totali",
        "message": str(count_downloads(pages)),
        "color": "df3b8a",
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: count_downloads.py RELEASE_PAGES_JSON")
    with open(sys.argv[1], encoding="utf-8") as file:
        pages = json.load(file)
    print(json.dumps(badge(pages), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
