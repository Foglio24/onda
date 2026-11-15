# Changelog (Windows)

Versions here are independent of iPhone/Mac (`v*`) and Android (`android-v*`). Releases are cut
from the git branch **`windows`** as tags **`windows-vX.Y.Z`** only — never repository "Latest".

## 0.1.0 (2026-11-15)

### Added
- **Seaglass for Windows 11** (Compose Desktop): Classic three-panel shell (library | page | queue), YouTube Music search + radio, AAC playback, account sign-in through the Seaglass website with library sync, and **automatic updates** like on the Mac — checks GitHub for `windows-vX.Y.Z` from the `windows` branch (never "Latest"), downloads the zip, verifies size and SHA-256, stages it and installs on restart or when quitting.
