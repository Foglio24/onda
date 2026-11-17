# Seaglass for Windows changelog

## 1.5.2 (2026-11-17)

### Added
- **The installer fetches what Seaglass needs from Windows**, on a new install and on every update (the app's own silent one too): the Microsoft Visual C++ runtime (ONNX Runtime's library, for the karaoke) and Microsoft Edge (Spotify's sign-in; Windows 11 has it, a Windows 10 may not), each only when the computer lacks it. Setup downloads Microsoft's own installer, checks that it is signed by Microsoft, runs it (Windows asks for permission once) and waits up to ten minutes for it. If one can't be installed, setup says so and goes on, so an update never leaves the app closed.

### Fixed
- **The karaoke failed on a computer without the Visual C++ runtime** ("UnsatisfiedLinkError … onnxruntime.dll", as on a freshly installed Windows): ONNX Runtime is now loaded from a folder of its own beside the runtime's DLLs that FFmpeg's package carries, so it no longer depends on the computer having them.
- **The space bar did nothing** in 1.5.1: it is now taken before whatever has the focus (a focused button took it as a click, or nothing got it), once per press (holding it doesn't toggle again and again), and every text field in the app keeps its spaces.

## 1.5.1 (2026-11-17)

### Changed
- **The player's buttons are in groups**: in the bar and in the full player, what the right side shows (In riproduzione, Testo, Coda), the sound's tools (Karaoke, Tempo, Timer) and the volume are set apart by thin lines, with room between them, instead of one row of eight icons.

### Added
- **The space bar plays and pauses**, anywhere in the window except where you are typing (a text field keeps its spaces).

### Fixed
- **The keyboard's media keys (play/pause, next, previous, also the ones on Fn + F keys)**: the app's keyboard hook now also takes them with Alt held, writes in the app's log whether it was installed ("Media keys: …"), and if the hook misses a press the window takes it instead (never both). If they still do nothing on a computer, that log line says why.
- **When the karaoke can't separate a song, it says why**: the message now ends with the kind of error and a few words of it (the full line is in the app's log, "Registro dell'app" in Settings), so a report can say what went wrong on that computer.

## 1.5.0 (2026-11-17)

### Added
- **AutoMix's options, as on the iPhone and the Mac** (Settings › Audio, under "AutoMix · Beta"): "Mix dal vivo" (off, AutoMix plans as it did before these options), "Stile" (Automatico, Blend, Taglio, Dissolvenza), "Durata del mix" (Breve up to 8 bars, Normale 16, Lunga 32), "Variazione di tempo" (Delicata, Normale, Ampia: how far apart two tempos may be for a mix on the beat, 4, 8 or 12 %), "Equalizzazione automatica" (off: only the volumes change), "Tieni l'album intero" (an album's songs played in order run on gapless), and "Mix Lab" with "Passaggio dei bassi", "Dissolvenza sul beat" and "Stile per energia". A change plans the queued next mix again at once.
- **"Avanti"**: what Next does while AutoMix plays: Taglio (as before), Mix veloce (the next song comes in over 3 seconds) or Mix a tempo (over one bar, from the playing song's next downbeat). Early in a song the next one is opened at once; if it isn't ready within 3 seconds, Next cuts as before.
- **"Segna il mix sulla barra"**: the progress bar shows a mark where the next mix or crossfade will start.
- **"Radio automatica"**: off, the queue ends instead of going on with songs like the last one.

- **Karaoke AI, as on the iPhone and Android** (Premium, the microphone button in the player bar and the full player): "Senza voce" takes the voice out of the song, "Solo voce" keeps it alone, "Intensità" Leggera, Media or Piena. The vocals are separated on this computer by the same model (UVR MDX-Net Voc_FT, 64 MB, downloaded once the first time, checksum checked) with ONNX Runtime, a piece of about 6 seconds at a time from where the song plays; the song goes on meanwhile and the karaoke comes in once the separation is far enough ahead, saying how far it is. The next song is separated while this one plays, so its karaoke is there from its first note. The newest three songs' separation is kept (in the cache), songs of 15 minutes or more aren't separated. The karaoke is taken from the app's own decode of the whole song, so it is on the engine's frames exactly, and it comes in and goes out over 20 ms: no click when it starts or stops. It is applied where each deck hands out its frames, so Tempo's time stretch (checked) and the crossfades go through it too.
- **The installer fetches the runtime the karaoke needs**: on a new install, when the Microsoft Visual C++ runtime (ONNX Runtime's library needs it; FFmpeg's already brings its own) isn't on the computer, setup downloads Microsoft's installer, checks that it is signed by Microsoft and runs it (Windows asks for permission once). A computer that has it is left alone, and so is an update (the app's own silent one: no permission prompt out of nowhere). If it can't be installed, setup says so and goes on: Seaglass works, only the karaoke needs it.

### Changed
- **Tempos are matched as on the Mac**: "Normale" matches songs up to 8 % apart in tempo (1.4.0 allowed about 25 %: wider gaps meant a stretched song); "Ampia" up to 12 %. Each song still covers half of the gap. Turn "Mix dal vivo" off to plan as in 1.4.0.
- AutoMix now analyses 80 seconds at the end and at the start of each song (it was 60), so a "Lunga" mix of 32 bars fits; songs analysed before keep working, and are analysed again only when "Lunga" needs the longer window.

### Not on Windows yet
- "Mix armonico" (keys), "Voci pulite" and "Coda d'eco" of Mix Lab: they need key and voice detection and an echo that the Windows engine doesn't have.

## 1.4.1 (2026-11-16)

### Fixed
- Buttons never break their label across lines any more ("Rina / mina" in a narrow playlist page): the buttons under a playlist's, an album's or an artist's title go on to a second line as a whole.

### Changed
- Seaglass for Windows is on the website and in the README, with its download; each Windows release now updates the website's "Download for Windows" to point at it.

## 1.4.0 (2026-11-16)

### Changed
- **AutoMix mixes songs further apart in tempo, as on the iPhone**: the two songs now meet halfway between their tempos, each changing by at most 12 %, so tempos up to about 25 % apart are mixed on the beat (148 → 120 or 120 → 97 BPM were plain crossfades: only 12 % in all was allowed, all of it on the next song). Over the 16 beats before the mix the song playing glides to the meeting tempo; both play at it during the mix; over the 16 beats after it the next song glides back to its own tempo, then plays untouched. Checked for steps, clicks and loudness jumps before, during and after the mix.

### Added
- **The mix banner**: over the player bar, "Mix tra 8 s" in the last seconds before an AutoMix mix, then a bar filling as the mix goes ("Mix in corso", or "Dissolvenza in corso" for a crossfade), with the next song and how it comes in.
- **Ricerche recenti**, as on the iPhone: with the search field empty, what you searched for (Enter) and what you picked from the results (songs, artists, albums, playlists), newest first, at most 20. A click plays or opens it again, right-click opens a song's menu, × removes one, "Cancella ricerche recenti" removes all. They stay on this computer only.
- **"+" says where the song went, as on Spotify**: "Aggiunto a Brani preferiti" at the bottom of the window with "Cambia", which opens "Salva in": Brani preferiti and your playlists to tick (or a new one). The tick of a saved song in the player bar opens "Salva in" too; the heart in lists says "Aggiunto a" / "Rimosso da Brani preferiti".

### Fixed
- Right-click on the search's top result, when it's a song, now opens its menu, as on any song.

## 1.3.2 (2026-11-16)

### Fixed
- **Updating could still leave Seaglass unable to start** ("Error opening ... Seaglass.cfg"): 1.3.1's installer started again outside the app at once, while the app was still quitting (it takes some seconds). Windows can't close Seaglass for the installer, so the files the app still held couldn't be replaced and the install stopped after deleting the others. An update now waits for the app to have quit before touching anything. Checked in Windows 11 with the real sequence (the installer started by the app, the app quitting 8 s later): 1.3.1's installer left 48 of 53 files and no Seaglass.cfg, this one installs every file.

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
