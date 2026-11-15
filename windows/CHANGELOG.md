# Seaglass for Windows changelog

## 1.1.0 (2026-11-15)

### Added
- **Tempo** (Premium, as on the iPhone): the player bar's speed button plays the music from 15 % slower to 15 % faster with the key locked (the note stays the same), until you reset it. While it's not at 0 % the songs follow without a crossfade or a mix, which would change the speed while heard.
- **Last.fm**, as on the iPhone: Settings → Last.fm with your own free API key, the account authorised in the browser, "now playing", and each song scrobbled after half of it or 4 minutes; scrobbles that can't go wait (even with the app closed) and go later in batches. The shared secret and the session are protected by Windows (DPAPI).

## 1.0.0 (2026-11-15)

Seaglass for Windows, rebuilt from scratch: the first version played nothing.

### The app
- **The Mac app's layout**: the sidebar with search and the library, the pages with back and forward, the player bar, the queue and the synced lyrics beside the page, and the full player (the cover large, the lyrics beside it).
- **It plays**: YouTube Music's Opus and AAC streamed in pieces as on the iPhone (seeking anywhere at once), downloads, and your own songs (MP3, FLAC, M4A, WAV, OGG, Opus…), decoded by FFmpeg. Songs follow without a gap, or with a crossfade of 1 to 12 seconds; "Volume uniforme" brings them to the same loudness.
- **Catalogue**: Home (Scelti per te, Mood, recent songs), search as you type (top result, songs, artists, albums, playlists), artist, album and playlist pages, Informazioni sul brano (label, release date, credits).
- **Library**: liked songs, playlists (create, rename, delete, reorder, import a YouTube Music link, save one from YouTube Music), downloads, history, your own songs from the folders you choose (only read, never changed).
- **AutoMix** (Premium, as on the iPhone): each song's first and last minute analysed (tempo, beats, bars, where the sound starts and ends), and the next song brought in as a DJ would: on a downbeat, the tempo moving gradually from one song's to the other's across the mix, the bass passing over half way, the song going out filtered; songs without a beat get a long blend, songs that fade out by themselves meet the next one in their fade. After the mix the song is heard exactly as it is (tested sample by sample, with no step and no jump in level across the mix).
- **Player**: shuffle, repeat (all, one), Riproduci dopo and Aggiungi in coda, the queue to reorder, the radio of the last song when the queue ends, the sleep timer, the equalizer with Spotify's presets, the audio output to use, the quality.
- **Account**: sign in through the account page and the library (liked songs, playlists, history) is the same as on the iPhone and the Mac, merged by the iPhone's rules (only what you removed elsewhere is removed here).
- **Windows**: the notification area (the music goes on with the window closed), the keyboard's media keys even with the window closed, start with Windows, keyboard shortcuts (Ctrl+P, Ctrl+←/→, Ctrl+↑/↓, Ctrl+L), light and dark theme, the accent colours, the 11 languages of the iPhone app.

### Installing and updating
- **An installer** (`Seaglass-Setup.exe`) instead of a zip: for your user only, without administrator rights, it asks whether to put an icon on the desktop (and whether to start with Windows), and uninstalls from Windows's Settings, leaving your library.
- **Automatic updates** from Seaglass for Windows's own releases (`windows-v…`, never the iPhone's): once at launch and every hour; the new installer is checked (size and SHA-256 as GitHub gives them) and installs silently when you restart or quit, opening the app again.
