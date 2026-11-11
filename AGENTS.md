# AGENTS.md

Guidance for coding agents and automated code review (Codex) in this repository.

## The project

Seaglass is a YouTube Music player. It talks to YouTube Music (InnerTube) directly from the
device; its only server is the optional account service (`server/account`), where the iPhone,
iPad and Mac app keep the library in sync. It comes in two apps:

- **iPhone and iPad**: SwiftUI, iOS 26 or later. The Xcode project is generated from `project.yml`
  with XcodeGen. The sources are in `Seaglass/` (`App`, `Models`, `Player`, `Services`, `Views`,
  `Utilities`). It is distributed as an unsigned IPA for sideloading and through an AltStore source.
  The same target also builds for Macs with Apple silicon (Mac Catalyst, iPad idiom, macOS 26 or
  later): CI signs it ad hoc, without the sandbox, sets `UIApplicationSupportsMultipleScenes` in
  its Info.plist (so it keeps playing with its window closed) and publishes `Seaglass-mac.zip`
  beside the IPA. Its AppKit plug-in (`Mac/Bridge`, target `SeaglassMac`, embedded in the Mac
  build only) puts it in the menu bar and installs updates; the app talks to it through
  `Seaglass/Services/MacBridge.swift`.
  Mac-only behaviour checks `ProcessInfo.processInfo.isMacCatalystApp` (so its text is compiled,
  and checked, in the iOS build too) or `#if targetEnvironment(macCatalyst)`.
- **Android**: Kotlin, Jetpack Compose and Media3, in `android/`, for Android 10 or later. It is
  distributed as APKs on GitHub Releases, tagged `android-vX.Y.Z`, not on Google Play.

Other folders:

- `Tools/` holds the iOS checks (one folder each, run with `bash Tools/<Name>/run.sh`) and the
  release, localization and download-count scripts.
- `.github/workflows/` holds CI: `build.yml` (iOS), `android.yml`, the AltStore source and the
  download counter.
- `server/account/` holds the account service: a Cloudflare Worker with D1 and the account's web
  page, deployed by `.github/workflows/account.yml` (see its README). As on Spotify, the account
  is managed on the page; the app (`Seaglass/Services/Account.swift`) signs in, shows it and syncs
  the library (`Seaglass/Services/LibrarySync.swift`).
- `site/` holds the website: one animated page (English and Italian, no third-party requests) served
  by a Cloudflare Worker, deployed from `main` by `.github/workflows/site.yml` (see its header for the
  variables). Its text is in `site/i18n.js` and, in English, in `site/index.html`; `npm test` in `site/`
  checks both and the page in Chromium (computer, phone, reduced motion, no JavaScript). The page must
  keep saying that Seaglass is unofficial and unaffiliated.
- `docs/` holds the README's screenshots.
- `AutoMix-listening/` holds listening material for AutoMix, not code.

## Conventions

- **The UI text in the code is Italian.** It is the localization key. Translations live in
  `Seaglass/Resources/<lang>.lproj/Localizable.strings`: English, French, Spanish, German,
  Portuguese, Simplified Chinese, Japanese, Russian, Turkish and Arabic. Android reads the same
  files at build time. Android-only text goes in `android/app/src/main/assets/l10n-android/`.
  Every new or changed user-visible string needs an entry in every language, with the same
  format specifiers (`%@`, `%lld`, ...) as the key. `it.lproj` stays empty.
- **Versions.** iOS uses `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, with
  `CHANGELOG.md`. Android uses `versionCode` and `versionName` in `android/app/build.gradle.kts`,
  with `android/CHANGELOG.md`. `versionCode` must always increase.
- **Releases.** iOS releases (`vX.Y.Z`) are the repository's "Latest" release, which the iPhone
  app's updater, the AltStore source and the README's IPA link read. Android releases are normal
  releases but never "Latest".
- **Comments.** They explain why, in plain English. Keep them accurate when the code changes.
- **Parity.** A feature described as "as on the iPhone" should behave the same on both apps. A
  deliberate difference belongs in the changelog.

## Building and checking

- **Android** (JDK 21, Android SDK platform 37 and build-tools 36), from `android/`:
  - `./gradlew testDebugUnitTest` runs the unit tests in `app/src/test`. Some of them (catalog,
    audio path, quality) talk to the real YouTube Music and skip themselves when YouTube refuses
    the runner.
  - `./gradlew assembleRelease` builds the APKs, one per ABI.
- **Account service** (Node 22), from `server/account/`: `npm ci`, then `npm test` runs the
  whole service end to end on a local copy.
- **Website** (Node 22), from `site/`: `npm ci`, `npx playwright install chromium`, then `npm test`;
  `npm run dev` serves it at http://127.0.0.1:8787 with the headers it is deployed with.
- **iOS** (macOS with Xcode 27):
  - `xcodegen generate`, then build the `Seaglass` scheme (for the Mac:
    `-destination 'generic/platform=macOS,variant=Mac Catalyst'`).
  - The logic checks are `bash Tools/<Name>/run.sh`: PlaybackCheck, LibraryCheck,
    EqualizerCheck, AutoMixCheck and the others listed in `build.yml`.
  - `python3 Tools/check_localization.py` checks the translations against the strings the
    compiler found, and `python3 Tools/check_images.py` checks the images.

## Publishing

The owner has asked for finished work to be **published automatically**, without waiting for a
confirmation, in every session. Once a change is done and its checks are green:

1. Merge the working branch into `main` by fast-forward only (merge `origin/main` into the branch
   first when the bots have moved it), never with a force push.
2. Release what changed: iOS and Mac with a `build.yml` run on `main` and `release=true` (it becomes
   "Latest"), then refresh the AltStore source; Android with `android.yml` and `release=true` (never
   "Latest"); the account page and the website deploy from `main` by themselves.
3. Check the result (release assets, "Latest", AltStore version) and tell the owner in Italian.

The guardrails stay: no release while a check is red (a live-service check that skipped itself is not
red), no skipped or disabled checks to get green, no force pushes, no secrets in the repository, and a
version bump always comes with its changelog entry. A change that could lose a user's data is the one
case to stop and ask first.

## Review guidelines

Write review comments in Italian. Keep code, identifiers and quoted text as they are.

Treat these as **P1**:

- **Translations.** A user-visible string added or changed without an entry in every
  `Localizable.strings`, or with format specifiers that differ from the key's.
- **Playback that can't be stopped or never ends.** For example, music that keeps playing after
  the app is swiped away, a foreground service or notification that is never stopped, or a
  player, audio session or wake lock that is never released.
- **Real-time audio code doing slow work.** This covers Android `AudioProcessor`s and the iOS
  render/tap blocks and DSP in `Player/`. Allocating, locking, logging, doing I/O or calling into
  the UI per buffer is a P1. Parameters shared with other threads must be safe to read from the
  audio thread (`@Volatile`, atomics, or values copied before use).
- **Threading.** On Android, ExoPlayer, `MediaController` and Compose state are used from the
  main thread only. On iOS, UI and `@Published` state are updated on the main actor.
- **Data loss.** Changes to stored data (library, playlists, downloads, preferences keys,
  `UserDefaults`/`SharedPreferences`, cached analyses) must keep reading what earlier versions
  wrote. Renamed keys are migrated, not dropped. Downloads and the library are never deleted
  except by the user. Account sync removes from a device only what the user removed on another
  device since the last sync (`LibraryMerge`), never what it couldn't send.
- **Fragile YouTube parsing.** InnerTube responses change without notice. Parsing must tolerate
  missing or unexpected fields: no force unwraps (`!`, `!!`, `as!`) or unchecked indexing on
  response data. A song, album or page that can't be parsed is skipped, not a crash.
- **Releases.** A version bump without its changelog entry, an Android `versionCode` that
  doesn't increase, an iOS release that wouldn't be "Latest", or an Android release that would
  be.
- **Security.** Anything that breaks the rules in [SECURITY.md](SECURITY.md).

Also check:

- **Energy and network.** No polling or network requests per frame or per player tick, and no
  timers left running in the background. Requests go through the shared HTTP clients (with their
  timeouts).
- **Tests.** New logic in AutoMix, the equalizer, stream choice, InnerTube parsing, the library
  or playlist import comes with a check: an iOS `Tools/*Check` or an Android test in
  `android/app/src/test`.
- **CI.** Changes to workflows keep checks that talk to the live service non-blocking where they
  already are, and don't skip or disable checks to get a green build.

Don't flag:

- Italian user-interface strings in the code. They are intended: the Italian text is the
  localization key.
- The Android activity's `scene` and `query` intent extras. They exist for CI screenshots
  (`android/Tools/screenshots.sh`).
- Live checks that skip themselves when YouTube refuses the CI runner. This is intended.
