# Seaglass for Windows 11

Compose Multiplatform Desktop app. Same Seaglass account as iPhone/Mac/Android (sign-in through
the website, library sync). **Automatic updates** like on the Mac: looks for `windows-vX.Y.Z` on
GitHub (never "Latest"), downloads `Seaglass-windows.zip`, checks size and SHA-256, stages it and
installs on restart or when quitting.

## Build

Needs JDK 21.

```bash
cd windows
./gradlew :app:test
# On Windows, to produce the folder the updater zips:
./gradlew :app:createReleaseDistributable -Pseaglass.version=0.1.0
```

Version comes from the first `## X.Y.Z` in [CHANGELOG.md](CHANGELOG.md); keep
`BuildConfig.VERSION_NAME` / `VERSION_CODE` in sync.

## Release

`.github/workflows/windows.yml` with `release=true` (or a `windows-v*` tag) publishes
`Seaglass-windows.zip` and must leave the repository's "Latest" on the iPhone release.
