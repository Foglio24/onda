# Changelog

## 1.8.1 (2026-10-26)

### Fixed
- **Swipe down to close the player again.** Dragging down on the player now moves it with the finger, and letting go far enough down (or with a flick) shrinks it back into the mini player, like the Music app. It works on the cover, the title and the top bar; with the lyrics or the queue open, on the header, so their lists still scroll. The interactive cover's own drag had been taking these swipes since 1.4.0, so only the ⌄ button closed the player. Sideways drags still tilt the cover.

## 1.8.0 (2026-10-26)

### Improved
- **Cooler iPhone.** Onda does less work in the background and redraws less on screen:
  - The full-screen player no longer redraws everything four times a second: only the progress bar follows the song, and the lyrics redraw only when the line changes.
  - The interactive cover's motion sensor no longer redraws anything while the iPhone is held still or lies on a table. It stops when the app is in the background or the screen is locked, and it is off with Reduce Motion, in Low Power Mode and while the iPhone is hot.
  - While the iPhone is warm or in Low Power Mode, Onda skips work for songs that may never play: links of songs on screen are no longer unlocked in advance, only the next song is cached (not the next two), and karaoke prepares the next song only when it starts.
  - Songs cached in advance are decoded at low priority, on the iPhone's efficiency cores, instead of at full speed.
  - The cover is no longer re-encoded at every song for a lock-screen player that doesn't use it.

### Changed
- **Downloads look like the Music app's.**
  - In song lists, a dotted circle marks a song waiting to download, a ring fills up while it downloads, and a small arrow marks a song that is on the iPhone, next to its length.
  - Albums and playlists have a download button that turns into a ring filling up as the songs arrive (tap it to stop), then into a tick once everything is saved.
  - **Library → Download** shows the number of songs, total length and space used, the songs still downloading with their own ring (tap to stop one, or stop all), and a choice of order: recently downloaded, title or artist. While songs download, the Download row in the Library shows how many are left with an overall ring.
  - **Storage** (from Download's menu, or Settings → Spazio e dati → Brani scaricati), like iPhone Settings → Music: a bar with Onda's downloads, the rest of the iPhone and the free space, then the space taken by each artist. Each artist lists their songs with format and size. Swipe left on an artist or a song to remove it from the iPhone.
  - A download that is running can now be stopped too (from the ring or the song's ··· menu), not only those waiting; stopping one is no longer reported as a failure.
  - Pieces of downloads interrupted when the app was closed are deleted at the next launch, so they no longer take up space.

## 1.7.0 (2026-10-26)

### Added
- **Artist and album pages.** An artist page has the picture, Play, Shuffle and the artist's radio, the top songs (with all songs a tap away), albums, singles, videos, playlists, similar artists and the biography. An album page has its songs, Play and Shuffle, and buttons to download the album or save it as a playlist. Public YouTube Music playlists open the same way, without importing them.
  - Open them from search, from the new **Vai all'artista** / **Vai all'album** in every song's ··· menu, or by tapping the artist's name in the player.
- **Richer search.** Results now show YouTube Music's top result, artists and albums as well as songs.
- **Normalize volume** (Settings → Audio → Volume uniforme, on by default). Songs louder than YouTube's reference level (-14 LUFS), as YouTube measures them, are turned down, so the volume stays similar from song to song. Quieter songs are left as they are.
- **The queue comes back after a restart.** Onda reopens on the song you were listening to, paused at the same point, with the rest of the queue; play carries on from there. The Home's "Riprendi da dove eri" card does the same.
- **Diagnostics** (Settings → Diagnostica). When Onda crashes or freezes, iOS hands a technical report to the app at a later launch; it is listed there and can be shared with a tap.

### For development
- CI takes screenshots of the main screens on an iPhone simulator, in Italian and English, to check the interface before a beta.
- CI checks the YouTube Music parsing (search, artist and album pages, loudness) against the live service, without blocking the build when YouTube is down.
- Debug symbols are kept with each build and attached to releases, to read crash reports.

## 1.6.0 (2026-10-26)

### Added
- **Updates from GitHub.** At every launch, or with Settings → Aggiornamenti → Cerca aggiornamenti, Onda asks GitHub for the latest release. You choose what happens when there is a new one:
  - **Avvisami:** a sheet shows the new version and its changelog, with buttons to download the IPA, share it or open the release.
  - **Scarica in automatico:** the IPA is saved straight away in the Files app (On My iPhone → Onda → Aggiornamenti), then the same sheet appears.
  - At launch the sheet appears at most once a day for the same version. IPAs of versions already installed are deleted.
  - Installing stays manual (Sideloadly, AltStore or SideStore): iOS doesn't let a sideloaded app replace itself.
- **Copyright, license and credits** in Settings → Informazioni, with links to the license and the source code.

### Changed
- Downloaded songs moved from the app's Documents folder, which is now visible in the Files app, to its private storage. The move happens once at launch, as an instant rename; if it fails the old folder keeps being used.
- The repository is public, under an all-rights-reserved license (see LICENSE). Work by others is listed in THIRD_PARTY_NOTICES.md.

## 1.5.0 (2026-10-26)

### Changed
- **A new Home**, all on Liquid Glass:
  - **Pick up where you left off.** When nothing is playing, a card at the top shows the last song and where it stopped; one tap carries on from there, followed by its radio. The position is saved every few seconds and on pause.
  - **Quick access.** Up to six compact tiles: favourites, Taste Mix, Rediscover and the month's top songs (with Last.fm), downloads, and the playlists you opened most recently. They replace the playlist, favourites and mix shelves and the Last.fm top list.
  - **Daily mixes.** Up to four mixes, one per artist you play most (history and favourites), each starting from a different song of theirs every day and continuing with YouTube Music's radio. Covers are a mosaic of your songs by that artist.
  - **Moods** are now tinted glass tiles, ordered by time of day: energy in the morning, focus in the afternoon, calm in the evening.
  - **Recently played** has smaller covers, so more fit on screen.

### Improved
- **Smoother pages.** Covers are kept in memory once decoded, so pages you go back to show them at once instead of loading them again, and small rows decode a small copy instead of the full-size cover (downloaded songs used to decode a 1080-pixel image for every row).
- **Lighter player.** Its blurred background is made once per song instead of being blurred live, which slowed down opening and closing the player.

## 1.4.1 (2026-10-26)

### Fixed
- A delayed retry can no longer replace a newly selected song with the previous song's audio.
- Radio responses and queue advancement stay attached to the queue that requested them, even when songs change during a slow request.
- Turning shuffle off preserves repeated songs in the queue; removing one occurrence keeps the others.
- Switching from a stream to a local copy after seeking no longer counts pauses or buffering as listening time.
- Last.fm tracks are reconciled with their YouTube versions in favourites and playlists instead of creating duplicate favourites after playback.
- Playlist downloads resolve Last.fm tracks before saving them and no longer report an unresolved playlist as already downloaded.
- Download failures are shown in the app with the affected song and the reason.
- Offline scrobbles are kept separately for each Last.fm account, including when the account changes during a request.

### Verification
- Added executable Swift regression checks for playback state, library identity/download state and Last.fm account isolation, run in CI before the iOS build.
- The existing karaoke reference comparison and English localization checks remain part of the IPA build.

## 1.4.0 (2026-10-25)

### Added
- **English.** The whole app is now also in English, including messages, errors and the karaoke and translation statuses. It follows the iPhone's language, and iPhones in any other language get English.
  - Settings → Lingua opens the app's iOS settings, where Onda can have its own language. iOS shows that choice when the iPhone has more than one preferred language.
  - The app now declares both languages, so iOS's own buttons inside it (Cancel, Delete…) use the app's language as well.
  - CI checks that every text in the code has its English version.
- **Lyrics translation.** Synced lyrics can show a translation under each line, in the language you pick (Settings → Testi). It uses Apple's on-device Translation:
  - Download the language once, then lyrics translate offline without slowing songs down.
  - Translation starts as soon as a song does, and the next song's lyrics are fetched and translated while the current one plays, so the translation is usually ready when you open the lyrics.
  - Lines appear as they are translated, repeated lines are translated once, and translations are kept for replays.
  - The 文A button in the lyrics panel shows or hides the translation.
  - For a song in a language you haven't downloaded, the lyrics panel offers to download it.
- **Interactive cover.** The player's artwork tilts in 3D with the iPhone and with your finger, with a sliding light reflection and a moving shadow. A double tap likes the song. You can turn it off in Settings → Aspetto.
- **AI karaoke mode.** The microphone button in the player removes the vocals or keeps only the vocals, at three strengths, like Apple Music Sing.
  - The separation uses the UVR MDX-Net "Voc_FT" model, converted to Core ML and run on the iPhone's Neural Engine and GPU. The model is included in the app, so there is nothing to download.
  - The song keeps playing while it is prepared, with the progress and the time left shown in the player, then switches to the separated stems at the same position.
  - Songs are separated in pieces of about 6 seconds, crossfaded together, which keeps memory use low.
  - The vocal/instrumental balance changes instantly.
  - The next song is prepared in advance, and stems are cached for replays. Settings → Karaoke shows how long the last song took and manages the cache.
  - CI converts the model and checks the app's own separation code against ONNX Runtime on every build.

## 1.3.4 (2026-10-25)

### Fixed
- **Crash 6–8 seconds into a song after a crossfade (introduced in 1.3.1).** At the end of the fade the old player was removed from the `MPNowPlayingSession` it had been created with, which crashed the app. Onda is back to the shared Now Playing info and command centers, as in 1.3.0.

### Known issue
- **On iOS 27 the lock screen and Dynamic Island player can belong to another music app.** Tapping it opens that app (e.g. Spotify), and closing Onda doesn't animate into the Dynamic Island. iOS 27 replaces the old Now Playing APIs with the new NowPlaying framework. Support for it (`MediaSession`) is already in the code, but it only switches on when the app is built with Xcode 27, and GitHub's Mac runners only have Xcode 26.6 so far. Settings → Informazioni shows which system is in use.

## 1.3.2 (2026-10-25)

### Added
- **Diagnostics in Settings → Informazioni.** They show the app's bundle ID and whether iOS accepted Onda as the Now Playing app. This helps track down why the lock screen and Dynamic Island player can open another music app.

## 1.3.1 (2026-10-25)

### Fixed
- **Tapping the player on the lock screen or in the Dynamic Island opened another music app (e.g. Spotify) instead of Onda.** Onda now registers its own Now Playing session and asks iOS to make it the active one whenever playback starts. Remote commands and song info go through that session.

## 1.3.0 (2026-10-25)

### Added
- **Theme colour.** Choose the app's accent colour in Settings: pink, red, orange, yellow, light green, dark green, mint, light blue, blue, indigo or purple.

### Improved
- **Songs start almost instantly, like on Spotify.**
  - The stream links of songs on screen (search results, shelves, playlists, queue) are unlocked in the background before you tap them.
  - Playback begins as soon as the first audio arrives instead of waiting for a large buffer.
  - The last played song is prepared at launch, which also warms YouTube's player script for the first song you tap.

## 1.2.0 (2026-10-25)

### Added
- **Four audio quality levels.** Wi-Fi, cellular and downloads each have their own setting.
  - **Maximum:** Opus ~160 kbps, decoded on the iPhone into Apple Lossless. Dolby Digital Plus or 256 kbps AAC is used instead when the video offers it.
  - **High:** AAC 128 kbps.
  - **Medium:** Opus ~70 kbps.
  - **Data saver:** HE-AAC 48 kbps.
- **Crossfade** between songs, adjustable from 0 to 12 seconds. It uses an equal-power curve, like Spotify.
- **Import from Spotify and Apple Music links.** Public playlists and albums can now be imported from Spotify (up to 100 songs) and Apple Music, as well as from YouTube and YouTube Music. Each song is matched on YouTube Music by artist, title and length.
- **Custom playlist covers** picked from Photos.
- **Download a whole playlist** with one tap. Downloads go through a queue, three at a time.
- **New app icon**, with dark and tinted variants for the iOS 18+ home screen.
- A "Prefer Dolby when available" setting.
- The last Opus error, if any, is shown in Settings.

### Fixed
- **Wrong song length on the progress bar.** YouTube's audio files often report a doubled length to AVPlayer, so the length now comes from the YouTube Music catalogue.
- **Seeking with the progress bar.** The player's swipe-to-dismiss gesture often swallowed the end of the system slider's drag, so the seek was never sent. A custom scrubber now always seeks where the finger lifts.
- **Seeking in streamed songs.** Songs still start streaming instantly, then switch to a local copy where seeking is reliable.
- **Slow start of the next song during a crossfade.**
  - The next two songs are cached ahead of time.
  - Downloads now fetch 1 MB ranges four at a time, because YouTube throttles a single full-file request to about playback speed.
- A crossfade no longer leaves silence when the next song is slow to start.
- "Maximum" quality no longer waits for the Opus decode. It starts in AAC and switches to Opus once it is ready.

## 1.1.0 (2026-10-25)

### Added
- **Playlists:** create, rename, reorder and delete them, and import public YouTube Music playlists.
- **Actions on every song:**
  - An "Add to playlist" sheet.
  - A "···" menu on every row.
  - Swipe right to like a song or add it to a playlist.
- **A real shuffle mode** that also applies to radios and mixes, plus repeat all / repeat one and a sleep timer.
- **Settings:**
  - Streaming quality for Wi-Fi, cellular and downloads.
  - Spatial audio.
  - An option to skip long compilations.
  - Lyrics size and animation style.
  - Colours taken from the album art.
  - Cache and history cleanup.
- **Library:** split into Favourites, Downloads, History and Playlists. Home gains playlist and favourite shelves.
- **Player badges** for format and bitrate, spatial audio and the sleep timer.

### Fixed
- Home, Library, Search and Settings had a plain background. They are now tinted with the colours of the album that is playing.
- The queue had square rows and a sticky header. Its rows are now rounded cards.
- Shuffle did nothing on radios.

## 1.0.0 (2026-10-25)

First release.
- YouTube Music search and song radios.
- Background playback, with lock screen, Control Center and AirPlay controls.
- Synced lyrics from LRCLIB, with auto-scroll and tap-to-seek.
- Last.fm scrobbling (now playing and offline queue), plus the Taste Mix and Rediscover mixes.
- Offline downloads, favourites and listening history.
- A Liquid Glass interface with a tab-bar mini player, and colours taken from the album art.
- A GitHub Actions workflow that builds an unsigned IPA for sideloading.
