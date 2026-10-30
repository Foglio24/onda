#!/usr/bin/env python3
"""Build a Shields endpoint badge from paginated GitHub release API responses."""

import json
import sys

IPA_NAMES = {"onda.ipa", "seaglass.ipa"}


def count_ipa_downloads(pages):
    if not isinstance(pages, list):
        raise ValueError("Expected a list of GitHub API pages")
    total = 0
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
                if asset["name"].lower() in IPA_NAMES:
                    downloads = asset.get("download_count")
                    if isinstance(downloads, bool) or not isinstance(downloads, int) or downloads < 0:
                        raise ValueError("Invalid download count")
                    total += downloads
    return total


def badge(pages):
    return {
        "schemaVersion": 1,
        "label": "download IPA totali",
        "message": str(count_ipa_downloads(pages)),
        "color": "df3b8a",
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: count_ipa_downloads.py RELEASE_PAGES_JSON")
    with open(sys.argv[1], encoding="utf-8") as file:
        pages = json.load(file)
    print(json.dumps(badge(pages), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
