# Changelog

## 1.4.0 (2026-10-25)

### Added
- **Lyrics translation.** Synced lyrics can show a translation under each line, in the language you pick (Settings → Testi). It uses Apple's on-device Translation:
  - Download the language once, then lyrics translate offline without slowing songs down.
  - The 文A button in the lyrics panel shows or hides the translation.
  - For a song in a language you haven't downloaded, the lyrics panel offers to download it.
- **Interactive cover.** The player's artwork tilts in 3D with the iPhone and with your finger, with a sliding light reflection and a moving shadow. A double tap likes the song. You can turn it off in Settings → Aspetto.
- **AI karaoke mode.** The microphone button in the player removes the vocals or keeps only the vocals, at three strengths, like Apple Music Sing.
  - The separation uses the UVR MDX-Net "Voc_FT" model, run on the iPhone by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and ONNX Runtime. The model is a 64 MB download, needed only once.
  - The song keeps playing while it is prepared, then switches to the separated stems at the same position.
  - The vocal/instrumental balance changes instantly.
  - The next song is prepared in advance, and stems are cached for replays. Manage the model and the cache in Settings → Karaoke.

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
