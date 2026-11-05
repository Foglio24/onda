# Changelog (Android)

## 0.2.1 (2026-11-05)

### Fixed
- **Lyrics translation works.** In 0.2.0 it stopped at once with an internal error: the release build's code shrinking emptied the parts ML Kit looks up by name, so the language of the lyrics couldn't be recognised. When a translation can't be made, the lyrics now say so plainly.

### Changed
- **Clearer Settings.** Each topic shows how it's set under its name (the qualities for Wi-Fi and cellular, the transition, the translation language, the theme colour, the downloaded songs and the space they take, the version), so a page is opened only to change something.

## 0.2.0 (2026-11-05)

### Added
- **Downloads.** Songs, albums and playlists (also the favourites and your own playlists) download to the phone and play without a connection: "Scarica" in a song's menu, "Scarica tutta la playlist" on a page, with the progress beside each song and in a notification. Downloads resume after the app is closed. Library → Download lists them; Settings → Storage shows the space they take and deletes them.
- **Audio quality as on the iPhone.** Separate qualities for Wi-Fi, cellular and downloads: Maximum (Dolby or AAC 256 kbps when YouTube offers them, otherwise Opus 160 kbps), High (AAC 128 kbps), Medium (Opus 70 kbps), Data saver (HE-AAC 48 kbps). The player shows the format playing.
- **Dolby when available** (Dolby Digital Plus, and Dolby Atmos on phones that decode it), and **uniform volume**, which brings every song to YouTube's reference loudness.
- **Crossfade** between songs, from 1 to 12 seconds (Settings → Playback → Transitions). Songs of the same album follow each other without a fade.
- **Lyrics translation** on the phone: "Mostra traduzione" in the lyrics puts each line's translation under it; the language is recognised by itself, and its model downloads once, then works offline. Settings → Lyrics chooses the language.
- **Bit-perfect output to a USB DAC** (Android 14 and later), as in LastWave: the audio reaches the DAC unchanged, at each song's own sample rate, without Android's mixer.
- **Pull the player down to close it**, from anywhere on it (the artwork too), as on the iPhone; the mini player opens with a swipe up.
- Settings are a short list of topics, each with its own page: Audio, Playback, Lyrics, Appearance, Language, Storage, Updates, About.

### Fixed
- Closing Seaglass from the recent apps now stops the music, as on the iPhone; "Riprendi da dove eri" remembers where it was.
- After three songs fail in a row, playback stops instead of running through the queue.

## 0.1.0 (2026-11-05)

### Added
- **Seaglass for Android.** The first version of the app for Android 10 and later, built with Kotlin, Jetpack Compose and Media3, from the same YouTube Music catalog as the iPhone app:
  - Search for songs, artists, albums and playlists; artist pages (top songs, albums, singles, similar artists), albums and public playlists.
  - A song starts a radio of similar ones; "Radio automatica" keeps the queue going when it ends, leaving out hour-long compilations.
  - Background playback with the media notification, lock-screen and Bluetooth controls, and audio focus (calls, other apps, headphones unplugged).
  - Audio straight from YouTube: Opus at the highest quality, or AAC 48 kbps with "Risparmio", loaded in ranges so songs start at once.
  - Full-screen player on the artwork's colours, synced lyrics from LRCLIB (tap a line to jump to it), the queue, shuffle, repeat and a sleep timer.
  - Favourites, your own playlists (also imported from a YouTube or YouTube Music link), the listening history and "Riprendi da dove eri".
  - Home with daily "Scelti per te", moods and the songs heard lately.
  - **Liquid glass:** the tab bar, the mini player, the search field and the player's controls are glass that refracts what scrolls behind (Android 13 and later; frosted on Android 12).
  - The iPhone app's eleven languages, with Arabic right to left; Android 13 and later can pick the app's language in the system settings.
  - "Cerca aggiornamenti" finds new versions on GitHub.
- Links from YouTube Music (songs, albums, playlists, artists) can open in the app.

### For development
- The project is in `android/`; CI builds the signed APK, checks the YouTube Music code, the audio links, the lyrics and the translations against the real services, and takes screenshots on an emulator.
