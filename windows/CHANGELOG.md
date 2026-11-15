# Seaglass for Windows changelog

## 1.0.0 (2026-11-15)

Seaglass for Windows, rebuilt from scratch: the first version played nothing.

### The app
- **The Mac app's layout**: the sidebar with search and the library, the pages with back and forward, the player bar, the queue and the synced lyrics beside the page, and the full player (the cover large, the lyrics beside it).
- **It plays**: YouTube Music's Opus and AAC streamed in pieces as on the iPhone (seeking anywhere at once), downloads, and your own songs (MP3, FLAC, M4A, WAV, OGG, Opus…), decoded by FFmpeg. Songs follow without a gap, or with a crossfade of 1 to 12 seconds; "Volume uniforme" brings them to the same loudness.
- **Catalogue**: Home (Scelti per te, Mood, recent songs), search as you type (top result, songs, artists, albums, playlists), artist, album and playlist pages, Informazioni sul brano (label, release date, credits).
- **Library**: liked songs, playlists (create, rename, delete, reorder, import a YouTube Music link, save one from YouTube Music), downloads, history, your own songs from the folders you choose (only read, never changed).
- **Player**: shuffle, repeat (all, one), Riproduci dopo and Aggiungi in coda, the queue to reorder, the radio of the last song when the queue ends, the sleep timer, the equalizer with Spotify's presets, the audio output to use, the quality.
- **Account**: sign in through the account page and the library (liked songs, playlists, history) is the same as on the iPhone and the Mac, merged by the iPhone's rules (only what you removed elsewhere is removed here).
- **Windows**: the notification area (the music goes on with the window closed), the keyboard's media keys even with the window closed, start with Windows, keyboard shortcuts (Ctrl+P, Ctrl+←/→, Ctrl+↑/↓, Ctrl+L), light and dark theme, the accent colours, the 11 languages of the iPhone app.

### Installing and updating
- **An installer** (`Seaglass-Setup.exe`) instead of a zip: for your user only, without administrator rights, it asks whether to put an icon on the desktop (and whether to start with Windows), and uninstalls from Windows's Settings, leaving your library.
- **Automatic updates** from Seaglass for Windows's own releases (`windows-v…`, never the iPhone's): once at launch and every hour; the new installer is checked (size and SHA-256 as GitHub gives them) and installs silently when you restart or quit, opening the app again.
