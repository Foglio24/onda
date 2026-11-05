# Changelog (Android)

## 0.3.0 (2026-11-05)

### Added
- **AutoMix**, as on the iPhone, now the default transition (Settings → Playback → Transitions). Each song's first and last minute are analysed on the phone, once: the tempo, the beats, the bars and where the sound starts and ends. Between two songs AutoMix then chooses:
  - **in time, like a DJ**, when both have a steady beat at close tempos (or at half or double): the next song comes in on its first downbeat at the playing song's tempo, the two play together for 8 or 4 bars while the bass passes from one to the other, the song leaving is filtered and fades, then the new song glides back to its own tempo;
  - **into the song's own fade-out**, when it fades by itself;
  - otherwise **a blend** on the last seconds of sound, with no silence left between the songs.
  Songs of the same album follow each other as on the album. The queue shows the next transition ("AutoMix · a tempo, 8 battute"), Settings → Playback the last one.
- The plain crossfade stays as a choice, from 1 to 12 seconds.
- **Equalizer**, as on the iPhone: Spotify's six bands (60 Hz to 15 kHz) and its 22 presets (Acoustic, Bass Booster, Bass Reducer, Classical, Dance, Deep, Electronic, Hip-Hop, Jazz, Latin, Loudness, Lounge, Piano, Pop, R&B, Rock, Small Speakers, Spoken Word, Treble Booster, Treble Reducer, Vocal Booster, and Flat), plus your own curve by dragging its points. When a preset raises frequencies, the overall volume comes down just enough not to distort. Settings → Audio → Equalizer, or the equalizer button in the player. With bit-perfect output on, it waits until that's off.

### Changed
- The crossfade and AutoMix share one engine: if AutoMix's analysis isn't ready in time, the songs crossfade instead of not mixing.

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
