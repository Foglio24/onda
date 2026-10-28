"""Writes a release's notes from CHANGELOG.md, for the GitHub release the app's updater shows.

Usage: release_notes.py <CHANGELOG.md> <version> [previous released version]

The notes are the version's section; when versions between it and the previous release were never
released, their sections follow it, each under its own heading, so the update sheet lists
everything new since the version people have. Then the install line.
"""

import re
import sys

HEADER = re.compile(r"^## (\d+(?:\.\d+)*)\b.*$", re.MULTILINE)


def sections(changelog):
    """(version, heading line, body) for each "## x.y.z" section, newest first."""
    matches = list(HEADER.finditer(changelog))
    result = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(changelog)
        result.append((match.group(1), match.group(0), changelog[match.end():end].strip()))
    return result


def notes(changelog, version, previous):
    found = sections(changelog)
    versions = [v for v, _, _ in found]
    if version not in versions:
        raise SystemExit(f"no section for {version} in the changelog")
    start = versions.index(version)
    end = versions.index(previous) if previous in versions and versions.index(previous) > start else start + 1
    chosen = found[start:end]
    if len(chosen) == 1:
        text = chosen[0][2]
    else:
        text = "\n\n".join(f"{heading}\n\n{body}" for _, heading, body in chosen)
    return text + "\n\n**Install:** download `Seaglass.ipa` below and sideload it as usual.\n"


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as file:
        changelog = file.read()
    previous = sys.argv[3] if len(sys.argv) > 3 else ""
    sys.stdout.write(notes(changelog, sys.argv[2], previous))
