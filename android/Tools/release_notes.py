"""Writes an Android release's notes: the version's section of android/CHANGELOG.md, then how to install.

Usage: release_notes.py <android/CHANGELOG.md> <version>
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "Tools"))
from release_notes import sections  # noqa: E402

INSTALL = (
    "\n\n**Install:** open this page on the phone, download `Seaglass-{version}.apk` below and open it; "
    "Android asks once to allow installs from the browser. Updates install over the app, keeping the library. "
    "Requires Android 10 or later.\n"
)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    changelog = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    version = sys.argv[2]
    found = {v: body for v, _, body in sections(changelog)}
    if version not in found:
        raise SystemExit(f"no section for {version} in the changelog")
    sys.stdout.write(found[version] + INSTALL.format(version=version))
