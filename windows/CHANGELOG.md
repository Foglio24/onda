# Seaglass for Windows changelog

## 1.3.1 (2026-11-16)

### Added
- **Your whole Spotify account** (Premium): "Accedi a Spotify" in the import window signs you in to Spotify in a Microsoft Edge window (once; Seaglass keeps that Edge profile of its own, "Esci da Spotify" forgets it), lists your playlists, private ones and those in folders too, and imports the ones you tick, every song, past the 100 of a public link. The songs are looked up with the same rules as a link or a file; one playlist ends on the same summary.

### Fixed
- **An update could leave Seaglass unable to start** ("Error opening ... Seaglass.cfg"): the app's launcher closes everything it started when the app exits, the installer among them, so it was stopped halfway through replacing the app. An update now restarts its installer outside the app first, so it finishes. Updating from 1.3.0 goes through this new installer, so it is covered too. If Seaglass already won't start, run the installer from the releases again.
- **"Riavvia e aggiorna" came seconds after the download bar was full**: the downloaded installer was read whole again to check it. It is now checked while it downloads, and the button comes with the full bar.

## 1.3.0 (2026-11-16)

### Added
- **Playlists from Spotify and Apple Music** (Premium, as on the iPhone): "Importa da Spotify, Apple Music o YouTube" (in Playlist, and in the library's "+") takes the link of a public playlist or album of Spotify, Apple Music, YouTube or YouTube Music (also with text around it, as apps share them, and Spotify's short links). Each song is looked up on YouTube Music with the iPhone's rules (the same title and artist, the same version: no live or remix in its place, a similar length), four at a time, saying how far it got.
- **Long Spotify playlists from a file**: Spotify's public page shows only the first 100 songs, so a whole playlist comes from a file, as on the iPhone: a CSV made by Exportify (the dialog opens exportify.net, where you sign in with Spotify and download any playlist whole) or Playlist1.json from Spotify's account data (you choose which of its playlists).
- **The import summary**: the songs now in the playlist, the ones to check (not found, search failed, the same recording twice, podcast episodes, unavailable rows) and, for each one not found, YouTube Music's likely recordings to choose from; the chosen one goes where it stood in the original. When Spotify's page may have stopped at 100 songs, the summary says so.

## 1.2.0 (2026-11-15)

### Changed
- **A new look, close to Spotify's**: black around three rounded panels, each border dragged to resize them (sizes kept from one launch to the next): "La tua libreria" on the left (liked songs, downloads, history, your songs and your playlists, shrunk to its covers when dragged narrow or when its title is clicked), the page in the middle, and on the right "In riproduzione" (the cover large, the song, "Informazioni sul brano", what comes next and AutoMix's plan), the queue or the lyrics. Home and the search sit in the middle of the top bar; settings and the account on the right. The player bar is laid out as Spotify's, and fits narrow windows (the song's title gives way, never the buttons).
- **Readable everywhere**: every text colour reads at least 4.5:1 on its background, the Mood tiles are darkened under their white names, light accents are darkened on the light theme, text on the accent is black or white as reads best, and long folder paths no longer push "Rimuovi" into a column of single letters.
- **The full player** (the cover in the bar, or the new full-screen button): the cover's colour behind it, previous, play or pause and next large in the middle with shuffle and repeat, the progress, and the buttons for the lyrics, their translation, the queue, Tempo, the sleep timer and the volume; the lyrics or the queue beside the cover.
- **The equalizer is in Settings**, drawn as Spotify's: six points on a curve, each dragged up or down.
- **AutoMix mixes much more often**: its plan follows the iPhone's, matching beats when the tempos are up to 12 % apart (they had to be within 6 %, so most pairs of songs got a plain fade), over 16 bars when they're close, the next song fully in by the bass swap on the middle downbeat; the mix starts on its planned downbeat to the sample (it could start up to 21 ms late, enough to hear the two kicks apart); if the next song isn't ready in time (the network), a crossfade instead of a mix out of step. Crossfades follow the iPhone's too: longer into a song's own fade-out, on a downbeat. The queue, the "In riproduzione" panel and the full player show what AutoMix is doing ("Analisi dei brani…", "a tempo, 8 battute", "dissolvenza di 9 s").
- **Tempo** as the iPhone's: the song's BPM, the change to a tenth of a percent (− and +), "Reimposta", the range (±8, 15, 25 or 50 %), and a real "Blocca tonalità" switch: on, voices keep their pitch; off, faster is higher, as on a turntable (before, the panel only said "Blocca tonalità").
- Video thumbnails are shown without their black bands.

### Added
- **Lyrics translation** (Premium, as on the iPhone): "Traduci" by the lyrics (in the panel and in the full player) shows each line's translation under it, in the app's language or the one chosen. Windows has no translator of its own, so the Seaglass account service translates them; it needs you signed in.
- **Registro dell'app** (Settings → Informazioni): a short diary of songs that couldn't play and of AutoMix's choices, to send with a screenshot when something goes wrong. It never holds tokens or addresses.

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
