# Changelog (Android)

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
