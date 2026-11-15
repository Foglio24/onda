# Seaglass for Windows

The Windows app, on the dedicated `windows` branch: Kotlin with Compose Multiplatform Desktop, for
Windows 10 (1809) and 11, x64. See the repository's `AGENTS.md` for the conventions and
`windows/CHANGELOG.md` for what changed.

## Layout

| Path | What it is |
| --- | --- |
| `app/src/main/kotlin/.../audio/` | FFmpeg decoding (`Decoder`), the bytes from YouTube or a file (`ByteSource`), the engine (`Engine`: two decks, gapless and crossfade, the equalizer, Java Sound), the player and its queue (`Player`) |
| `.../data/` | YouTube Music (`InnerTube`, `Streams`, shared with Android), lyrics (LRCLIB) and their translation (the account service), the library, downloads, the user's own songs |
| `.../account/` | The Seaglass account: sign-in through the page (PKCE), the token with DPAPI, library sync (`LibraryMerge`, the iPhone's rules) |
| `.../ui/` | The window, laid out as Spotify's: the top bar, three resizable panels (the library, the page, what's playing / the queue / the lyrics), the player bar, the full player, settings (with the equalizer) |
| `.../update/` | Updates from `windows-v*` releases, checked by size and SHA-256 |
| `app/src/main/l10n-windows/` | Text only the Windows app shows; the rest comes from the iPhone app's `Localizable.strings` |
| `installer/Seaglass.iss` | The Inno Setup installer |

## Building

```sh
./gradlew :app:test                                   # tests (add -Plive=true for YouTube Music)
./gradlew :app:runDev -Phome=/tmp/seaglass            # run it with a separate profile
./gradlew :app:runDev -Pheadless=true -Phome=…       # …and no sound card (CI, Xvfb)
./gradlew :app:runDev -Pwindow=980x640 -Phome=…      # …at another window size (the smallest is 980×640)
```

The installer is built on Windows by `.github/workflows/windows.yml`, which also installs it
silently, runs `Seaglass.exe --self-test`, checks the desktop icon and the sign-in address, and
uninstalls it. With `release=true` (from the `windows` branch only) it publishes
`windows-vX.Y.Z`, never "Latest".
