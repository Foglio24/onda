# Handoff: read this before you touch anything

This file is for an AI agent (ChatGPT/Codex or another) taking over this repository with no memory of
earlier sessions. It was written on 2026-11-15 by the agent that did the work until then. Read it
whole, then `AGENTS.md` and `SECURITY.md` on the branch you work on. Where this file and `AGENTS.md`
disagree, `AGENTS.md` wins. When you finish something, update the "State" and "What's missing"
sections here so the next agent starts from the truth.

## 1. The owner and how to work with them

- **Always answer in Italian**, in plain words: what changed, what they have to do (if anything),
  what is not verified. They are not a developer. Code, comments, commit messages and repository
  docs stay in English.
- They want **finished, published work**, not questions. Publish automatically once the checks
  are green (`AGENTS.md`, "Publishing"). Stop and ask only before something that could lose a
  user's data, or when you are truly blocked on a decision only they can make.
- They report bugs with screenshots or screen recordings. Reproduce, find the real cause, fix it,
  add a check, publish. Do not claim something works unless a test or CI run showed it.
- They were burned by an earlier agent (Cursor) that shipped a Windows app that "didn't work at
  all". Never ship something you have not built and tested.

Standing rules from the owner (on top of `AGENTS.md`):

1. Never add simulator UI tests.
2. Whenever AutoMix changes (any platform), test specifically that the audio never jumps: no
   step, click or loudness jump at the start, during and after the mix.
3. Every new or changed user-visible string gets an entry in all 10 languages (en, fr, es, de, pt,
   zh-Hans, ja, ru, tr, ar) with the same format specifiers. `it.lproj` stays empty (Italian is the
   key).
4. iOS releases are "Latest". Android and Windows releases are **never** "Latest".
5. No force pushes, `main` only by fast-forward, no secrets in the repository, no YouTube
   bot-check evasion, a version bump always with its changelog entry.

## 2. State on 2026-11-15

| App | Version | Release tag | Where the code is |
| --- | --- | --- | --- |
| iPhone, iPad, Mac | 1.36.12 (build 91) | `v1.36.12`, the repository's "Latest"; AltStore source at 1.36.12 / 91 | `main` |
| Android | 0.4.3 (versionCode 8) | `android-v0.4.3` | `main`, `android/` |
| Windows | 1.5.0 | `windows-v1.5.0` (not Latest; `windows-v1.3.1` is marked pre-release: its installer broke updates) | branch **`windows`**, `windows/` |
| Account service | deployed | none | `main`, `server/account/` (deploys by itself) |
| Website | deployed | none | `main`, `site/` (deploys by itself) |

See `git log` on `main` and `windows` for the heads; this file is updated with every release.

**Waiting on the owner, not on code:** the GitHub secret `TICKETMASTER_API_KEY` (read by
`.github/workflows/account.yml`). Without it the account service can't fetch concerts, so the
"events near you" card under the classic-style player stays empty. Don't put a key in the
repository; remind the owner if events come up.

## 3. Branches: get this right

- `main`: iPhone/iPad/Mac (`Seaglass/`, `Mac/`), Android (`android/`), the account service, the
  website, `Tools/`. **The Windows code is not on `main`.**
- `windows`: `main` as of `45e33b9` plus `windows/`, `.github/workflows/windows.yml`, and Windows
  sections in `AGENTS.md`, `README.md`, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`. All Windows work
  and Windows releases happen here.
  - Never merge `windows` into `main`, and never bump or tag Windows from `main`.
  - The Windows build reads the iPhone app's translations (`Seaglass/Resources/*.lproj/Localizable.strings`)
    from the `windows` branch's own copy. When you need newer strings from `main`, merge
    `origin/main` into `windows` with a merge commit (no rebase, no force push).
- `cursor/windows-desktop-34a4`: Cursor's broken first attempt (released as `windows-v0.1.0`, a zip
  with no updater). Ignore it; don't delete it.
- The many `cursor/*`, `feature/*`, `test/*`, `claude/*` branches are old. Don't work on them.
  Start new work from `main` (iOS/Android) or `windows` (Windows) on a new branch, then publish as
  `AGENTS.md` says.

## 4. The Windows app (where the active work is)

The owner asked for: a Windows app with **every feature of the iPhone/Mac app**, automatic updates
that only follow Windows releases, and a real installer that lets the user choose the desktop icon.
The installer and the updater are done; feature parity is partly done (section 5).

Since 1.2.0 the window looks **as close to Spotify's as possible without copying it** (the owner's
request): black around three rounded panels whose borders are dragged to resize them (library on the
left, page in the middle, "In riproduzione" / queue / lyrics on the right), Home and the search in
the middle of the top bar, Spotify's player bar, a full player with every control (previous, play,
next, shuffle, repeat, lyrics, translation, queue, Tempo, timer, volume), the equalizer inside
Settings. The owner complained about **unreadable text**: keep every text colour at 4.5:1 on its
background (`Theme.kt` has `contrast()` and `Color.forWhiteText()`), test the smallest window
(`-Pwindow=980x640`) and look for text squeezed into columns (give the long text `weight` and
`maxLines = 1`, never the button beside it).

Stack: Kotlin 2.1 on JVM 21, Compose Multiplatform Desktop 1.8, Gradle wrapper, OkHttp 5,
org.json, JNA (Windows APIs), JavaCPP FFmpeg 7.1 (decoding). Google's Maven Central mirror is
first in `settings.gradle.kts` because Maven Central sometimes refuses CI.

Map (`windows/app/src/main/kotlin/com/onda/seaglass/`):

| Path | What it does |
| --- | --- |
| `Main.kt` | Start-up order, tray icon, window, keyboard shortcuts |
| `WindowsIntegration.kt` | Single instance (loopback socket), start with Windows (registry), media keys (low-level keyboard hook) |
| `SelfTest.kt` | `Seaglass.exe --self-test`: what CI runs after a real install |
| `audio/Decoder.kt`, `ByteSource.kt` | FFmpeg decoding through custom I/O; output 48 kHz stereo float |
| `audio/Engine.kt` | Render thread, two decks with ring buffers, gapless, crossfade, AutoMix transitions, equalizer, volume, Tempo; Java Sound output or a null sink |
| `audio/TimeStretch.kt` | WSOLA, Tempo with the key kept |
| `audio/Player.kt` | Queue, shuffle/repeat, play next, radio at the end of the queue, sleep timer, picks local file / download / cache / stream, prepares AutoMix 75 s ahead |
| `audio/automix/` | `Analyzer` and `Planner` copied from Android, `AutoMix.kt` (analysis cache, plan, `Transition`) |
| `data/` | `InnerTube`, `Streams`, `Lyrics` (shared with Android), `RecentSearches` (the search's history, local only), `PlaylistImport` (Spotify/Apple Music/YouTube links and CSV/JSON files, matched on YouTube Music with the iPhone's rules; `spotify/` feeds it the playlists of the user's own Spotify account, read from Spotify's web player in an Edge window driven over DevTools, with a profile of its own), `LyricsTranslator` (through the account service's `POST /v1/translate`, Workers AI), `Library`, `Downloads` (+ `SongCache`), `LocalMusic`, `Recommendations`, `SongDetails`, `LastFM` |
| `account/` | Seaglass account: PKCE sign-in in the browser, callback through the `com.onda.player.auth:` protocol, token protected with DPAPI, sync (`LibraryMerge`, the iPhone's rules), Premium (`Account.unlocks()`) |
| `update/AppUpdater.kt` | Updates from `windows-v*` releases only |
| `ui/` | `Shell.kt` (top bar, the three resizable panels, library), `PlayerBar.kt` (bar, controls, Tempo panel), `Panels.kt` (now playing, queue, lyrics with translation, full player), `Theme.kt` (palette), pages, settings with the equalizer |
| `core/` | HTTP, JSON, translations (`L10n`, `tr("Italian key")`), paths, settings, `Log` (the app's log the owner can send: `%LOCALAPPDATA%\Seaglass\Logs\seaglass.log`) |

Rules the code depends on (break one and something fails in ways tests may not catch):

- **The audio render thread never allocates, locks or logs.** Shared parameters are `@Volatile` or
  copied before use.
- **JavaCPP limits callback instances per type.** All decoders share one pair of FFmpeg I/O
  callbacks with an opaque id (`Decoder.kt`, `Io`). Creating callbacks per decoder broke
  concurrent decoding ("Unsupported audio file").
- **Streams** are fetched as 512 KB ranged chunks (`&range=`), four ahead, and the whole song goes
  to `SongCache`. YouTube stream URLs are bound to the IP that requested them.
- **AutoMix**: the planner (`automix/Planner.kt`) follows the iPhone's, shaped by `MixOptions` (Settings
  › Audio › AutoMix: Mix dal vivo, Stile, Durata, Variazione di tempo, equaliser, Mix Lab, Avanti; "Mix
  dal vivo" off is `MixOptions.LEGACY`, the planning before the options): beats matched up to the tempo
  gap chosen (8 % by default, split between the two songs; 16 bars when within 6 %, 32 for "Lunga" over
  the 80 s analysis window), otherwise a crossfade (longer into a song's own fade-out). Not ported:
  Mix armonico (keys), Voci pulite, Coda d'eco (no key or voice detection, no echo in the engine).
  `Engine.mixNow` does "Avanti"'s quick mix and its bar-long mix from a downbeat (to the frame). The
  engine starts the mix on its planned frame (it splits the block), and drops the plan for a
  crossfade if the next song isn't ready by then. The incoming song's rate is exactly 1.0 when the
  transition ends; after a tempo glide the deck settles on a whole sample and plays untouched.
  Since 1.4.0 the two songs meet halfway between their tempos as on the iPhone (each ≤ 12 %, so
  up to ~25 % apart): `Transition.rateBefore` glides the outgoing song over the 16 beats before the
  mix, `rateAfter` the incoming one back over 16 of its beats after it (the engine's `soloRate`).
  AutoMix's decisions go to the app's log; when the owner says "AutoMix doesn't work", ask for it. `AutoMixEngineTest` checks no step
  beyond the songs' own, no loudness jump over 3 dB between 50 ms windows, exact samples after the
  mix. Keep it green and extend it with every AutoMix change.
- **Media keys** are handled only by the keyboard hook on Windows; handling them in the window too
  made them count twice.
- **Secrets** (account token, Last.fm session) only through DPAPI (`SecureStore`), never in the
  settings file or logs.
- **Updater**: only release assets named `Seaglass-Setup.exe` under
  `https://github.com/Foglio24/onda/releases/download/windows-v…/`, size and GitHub's SHA-256
  digest checked (again right before running), run with
  `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS` on restart or quit.
  The jpackage launcher keeps the JVM and everything it starts in a kill-on-close Windows job, so
  the installer would die with the app halfway through the copy (the app then fails with "Error
  opening ... Seaglass.cfg"). `Seaglass.iss`'s `InitializeSetup` therefore restarts an update
  (`/SEAGLASSUPDATE=1`) through WMI `Win32_Process.Create`, outside the job, with
  `/SEAGLASSDETACHED`. Keep it: it is what makes every update, from any older version, finish.
  That copy then waits (up to two minutes) until Seaglass.exe can be opened exclusively, i.e. the
  app has quit: Restart Manager can't close Seaglass (it asks for a reboot), and without the wait the
  install stopped on the files the quitting app still held, after deleting the rest.
  The checksum is computed while downloading (`copyHashing`), so "Riavvia e aggiorna" follows the bar.
- **Installer** (`windows/installer/Seaglass.iss`, Inno Setup 6): per user, no admin rights,
  `{localappdata}\Programs\Seaglass`; tasks "desktop icon" (checked) and "start with Windows"
  (unchecked); registers the sign-in protocol; uninstalling keeps the user's library.
- **Data**: `%APPDATA%\Seaglass` (library, settings), `%LOCALAPPDATA%\Seaglass` (cache, downloads,
  updates). `-Dseaglass.home=<folder>` (or `-Phome=` with `runDev`) moves both, for tests.
- **Translations**: UI text is `tr("Italian text")`. Keys come from the iPhone app's
  `Localizable.strings` plus Windows-only ones in `windows/app/src/main/l10n-windows/<lang>.strings`.
  `L10nTest` fails if a `tr()` key is missing in any language or its specifiers differ.
- **Premium** features are locked behind `Account.unlocks()` as on the iPhone (AutoMix, Tempo,
  link import, lyrics translation, and every Premium feature you add).
- **Tempo**: `Engine.keyLock` on uses `TimeStretch` (WSOLA, pitch kept); off uses the deck's
  variable-rate reading (pitch follows, as a turntable). `TempoKeyLockTest` checks both.

Build and check, from `windows/` (JDK 21):

```sh
./gradlew :app:test                               # all tests; add -Plive=true for YouTube Music
./gradlew :app:runDev -Phome=/tmp/sg -Pheadless=true   # run with its own profile, no sound card
```

CI (`.github/workflows/windows.yml`, runs on pushes to `windows` touching `windows/**`): tests on
Ubuntu (the live YouTube test is non-blocking), then on `windows-latest` it builds the app and the
installer, **installs it silently**, checks the exe, the desktop shortcut and the protocol key,
runs `--self-test` (FFmpeg decodes Opus, DPAPI works), uninstalls it and checks it's gone.

Releasing Windows:

1. Add `## X.Y.Z (YYYY-MM-DD)` at the top of `windows/CHANGELOG.md` with what changed (the app's
   version comes from that heading; it must increase).
2. Push to `windows`; wait for CI to be green.
3. Dispatch `windows.yml` on ref `windows` with `release=true`.
4. Check: release `windows-vX.Y.Z` exists with `Seaglass-Setup.exe` (about 130 MB) and a sha256
   digest, it is **not** "Latest", and "Latest" is still the iOS `v…` release. Installed apps update
   themselves within the hour or on the next start.

## 5. What's missing on Windows (the owner wants all of it), in order

Port from the Android code when it exists (same Kotlin, same server formats), otherwise from Swift.
Each one: Premium-gated where it is on the iPhone, translated in all languages, with tests,
released as a new `windows-v` minor version.

1. **Windows media controls (SMTC).** The volume flyout / lock-screen media panel doesn't show
   Seaglass; only the media keys work (keyboard hook). Needs the WinRT
   `SystemMediaTransportControls` (via JNA/COM or a small native helper). iPhone counterpart:
   `Seaglass/Player/SystemNowPlaying.swift`.
2. ~~Karaoke AI~~ done in 1.5.0 (`audio/karaoke/`). It differs from Android: the song is decoded whole,
   once, into a file (`KaraokeStems`' `.song`) and the karaoke is `vocalsGain·vocals + instrumentalGain·(song −
   vocals)` taken from that decode inside `Deck.readInto` (`KaraokeTap`), because a WebM seek is not
   sample-exact (a 1 ms timebase and Opus's pre-skip), so the deck's frames can't be trusted to line up
   with a separately decoded piece. Checked with the real model on macOS only (`KARAOKE_MODEL=<file>`
   runs `KaraokeModelCheck` and `KaraokeFlowCheck`); how it sounds on real songs, and how fast the
   separation is on the owner's PC, is not verified. The installer downloads the Visual C++ runtime
   (and Microsoft Edge) when missing, on installs and updates alike (`Seaglass.iss`, `PrepareToInstall`; a failure only warns). Only ONNX Runtime needs the runtime, and `OrtNative` loads it beside JavaCPP's own copy of the DLLs (found: a Parallels VM without the runtime failed with `UnsatisfiedLinkError … onnxruntime.dll` in 1.5.0/1.5.1; the fix in 1.5.2 is untested on a clean Windows). That path is untested on a clean Windows.
3. **Song recognition** (Premium): iPhone only so far (`Seaglass/Services/MusicRecognizer.swift`,
   `RecognitionSignature.swift`, `RecognitionAPI.swift`, `RecognitionOperation.swift`,
   `Views/RecognitionView.swift`). Microphone through Java Sound `TargetDataLine`.
4. **Podcasts**: `Seaglass/Services/InnerTube+Podcasts.swift`, `PodcastLibrary.swift`,
   `Views/PodcastViews.swift`.
5. **Classic style's player cards** (artist, events, credits; the window itself is already Spotify-like):
   `Seaglass/Views/InterfaceStyle.swift`, `ClassicSongCards.swift`.
6. Smaller gaps: "what's new" after an update (`Services/ReleaseNotes.swift`), the playlist mix
   views (`Views/MixViews.swift`), and AutoMix quality: Windows uses Android's analysis; the
   iPhone's is better (`Player/BeatThis.swift`, `VocalDetector.swift`, `MixDesign.swift`).
7. Nice to have: a smaller installer (list the
   jlink modules instead of `includeAllModules`). The installer isn't code-signed, so Windows shows
   "unrecognized app"; there is no certificate, don't invent one.

## 6. Not verified yet

- **Streaming and sound on a real Windows PC** are tested only by the owner (they use it). The
  development machine couldn't play YouTube streams (URLs bound to another IP) and has no sound card;
  CI checks decoding, install, DPAPI and the updater, not live playback. Test AutoMix and the engine
  with real music from local files: Creative Commons songs from Jamendo
  (`https://prod-1.storage.jamendo.com/download/track/<id>/mp32/`, ids in
  `AutoMix-listening/CREDITS.txt`) played through `Engine` with a capture sink (see
  `AutoMixEngineTest`); never commit them. A local HTTP server answering `&range=a-b` stands in for
  YouTube's streams (`StreamSource`).
- **Spotify import** reads Spotify's public embed page (first 100 songs, no account) and files
  (Exportify's CSV, Spotify's Playlist1.json) for longer playlists, as the iPhone does. Logging in
  to Spotify from the app was tried in a local session (an Edge window) and dropped: Spotify's Web
  API needs a developer app the owner would register, and its web player's private token isn't
  something to scrape. The owner's Mac may still hold that local commit (`afb8dda`, never pushed);
  it isn't needed.
- **Lyrics translation** was tested against a stand-in for Workers AI (the account service's
  tests); the live endpoint answers, but a real translation needs a Premium account's token.
- Artist pages may come back reduced (no albums) from some IPs.
- Users of Cursor's `windows-v0.1.0` zip won't be updated automatically: they must install
  `Seaglass-Setup.exe` once.

## 7. Traps already hit (don't repeat them)

- OkHttp 4's nullable body broke the shared Android code: use OkHttp 5.
- `AVFMT_FLAG_CUSTOM_IO` isn't in the FFmpeg bindings: the value is `0x0080`.
- A deck short of data during a mix caused gaps: read only what both decks have (`available()`).
- InnerTube's song-search filter sometimes returns nothing: fall back to the plain search.
- `return@repeat` in Kotlin is a `continue`, not a `break` (it broke the sync loop).
- Tests that run faster than real time race the player: the AutoMix test paces its sink at 20×.
- A Kotlin parameter named `size` hides `PointerInputScope.size` inside `pointerInput { }`.
- The screenshot helper must never `pkill -f seaglass`: it kills the shell running it (its command
  line holds the path). Kill `seaglass.MainKt` instead.
- Touch wording ("Tocca…") is wrong on a PC: use "Fai clic…".
- iOS: `Tools/*Check` scripts run on macOS only; CI (`build.yml`) runs them.

## 8. Releasing the other apps (short version of `AGENTS.md`)

- **iPhone/iPad/Mac**: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` +
  `CHANGELOG.md`; fast-forward `main`; dispatch `build.yml` on `main` with `release=true` (cancel
  the duplicate run the push started); check `v…` is "Latest" with the IPA and `Seaglass-mac.zip`;
  dispatch `altstore-source.yml` and check the source shows the new version.
- **Android**: bump `versionCode` (must increase) and `versionName` + `android/CHANGELOG.md`;
  dispatch `android.yml` with `release=true`; check `android-v…` is not "Latest".
