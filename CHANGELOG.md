# Changelog

## 1.36.0 (2026-11-12)

### Added
- **Light and dark mode** (iPhone, iPad and Mac). **Settings › Aspetto › Modalità**: **Automatica** (as the device, the default), **Chiara** or **Scura**, for the whole app in both styles. In the light mode Classico has white pages, light grey cards and black text; the player stays dark on the cover's colours, as in the common streaming apps. The classic pages are plain (no wash of the cover's colour under their header).

### Changed
- **The classic player, as the common streaming apps'.** It fills the screen with the cover as wide as the screen, and scrolls down to **Anteprima del testo** and **Prossimi brani** (the next three songs, **Apri la coda**); pulling it down past its top closes it.
- **The queue opens as a sheet over the classic player**, as the common streaming apps': half or full height, with Coda and what plays, the song playing in green with play, the next songs with their handles only (no red delete buttons), and **Riproduzione casuale** and **Timer** at the bottom. It no longer squeezes into the player between the controls and the lyrics.
- **The lyrics' preview under the classic player**: four lines from the one before the line being sung, wrapped in full (the button no longer covers them), sung ones white and the next ones dark, on the cover's colour; its translation button works and shows the translation under each line.
- Under the classic player's controls, **the name of the headphones or speaker** the sound goes to, in green.
- **The lyrics open in the classic style**, full screen on the cover's colour: the lines large on the left, the ones already sung white and the ones to come dark, the line being sung a third of the way down; the scrubber and play under them, and the karaoke. They no longer open in Seaglass's lyrics view. The queue opens on its own page.
- **The profile menu slides in from the left** over the page, with your profile at the top, then Recenti and Impostazioni e privacy; a tap beside it or a swipe to the left closes it.

### Fixed
- **The profile button and the pages' titles sat off-centre.** The system's toolbar wrapped the profile in a wider glass capsule and cut "Cerca" and "La tua libreria" off: the main pages now have their own header row (the profile, the title or the Home's filters, the page's buttons).

## 1.35.3 (2026-11-12)

### Fixed
- **The classic profile menu sat off-centre** (a gap on the right, especially on iPad). It now opens full-width like the other pages.
- **Dragging songs was missing in Classico** on the queue (no handles), playlists (only buried in ···) and search (list swipe fought the new look). The queue always shows drag handles; playlists and Preferiti have a clear reorder control; search uses the horizontal drag-to-queue gesture.

### Changed
- **Classic lyrics card** under the player — and under the queue when that panel is open: peek lines, translate affordance and **Mostra testo**, coloured from the cover.
- **Settings in Classico**: black page, flat grey section cards, green icons instead of the multicolour Seaglass tiles; the sheet opens full-width.

## 1.35.2 (2026-11-12)

### Fixed
- **The iPhone and Mac builds of 1.35.1 failed to compile.** The classic full player's layout and the Seaglass one were two different opaque view types in the same `if`; both apps now build again.
- **The classic daily-mix caption had no English (or other) translation**, so packaging the IPA stopped after a successful compile. `Mix %lld · %@` is in every language now.

### Changed
- **Classico on the Mac** (sidebar and player bar). Choosing Classico now restyles the floating sidebar (flat black, green selection, La tua libreria / Brani che ti piacciono) and the bottom player bar (flat elevated capsule, white play button, green shuffle/repeat and progress), instead of leaving Apple Music's glass chrome. The Home's shelf arrows and hover play badges follow the same look.

## 1.35.1 (2026-11-12)

### Changed
- **Classico closer to the common streaming apps** (iPhone and iPad). Pure black pages; Home opens with Tutti / Musica / Podcast pills, an eight-tile quick-access grid with no title, **Continua ad ascoltare** and **Recenti** (with Mostra tutto); Cerca has a white **Cosa vuoi ascoltare?** field, Musica / Podcast cards above Sfoglia tutto, and recent searches with × to clear; La tua libreria has Playlist / Podcast / File locali pills, Recenti + list/grid, and dense rows (Brani che ti piacciono pinned in purple); playlist pages put download / share / ··· beside shuffle and the green play; song ··· opens a bottom sheet of actions instead of the system menu.
- **The profile button opens a classic menu** (name, Profilo, Recenti, Impostazioni e privacy) — not friends' listening or messages, which Seaglass doesn't have.
- **The classic full player**: source in the header, the current lyric under the cover, green check, scrubber with a thumb and remaining time, AirPlay / share / queue, and an **Anteprima del testo** card that opens the lyrics.

## 1.35.0 (2026-11-12)

### Added
- **A second look for the whole app: Classico** (iPhone and iPad). **Settings › Aspetto › Stile dell'interfaccia** now offers **Seaglass** (Liquid Glass, as it was) or **Classico**: black and flat, in green, laid out as the most common streaming apps. The same app, features and pages in both; only how they look changes, and it switches at once.
  - **Tabs along the bottom**: Home, Cerca and La tua libreria, over a fade to black, with the mini player above them in the colours of the cover (song, artist, output, play, and a thin line for where the song is). The settings open from the round profile button at the top of the main pages.
  - **Pages** on near-black with a faint wash of the cover's colour at the top; nearly square covers; flat grey cards and buttons instead of glass.
  - **Home**: the shortcuts as flat grey tiles with the cover against the edge; the moods as solid coloured tiles.
  - **Cerca**: **Sfoglia tutto**, twenty coloured tiles of genres and moods (Pop, Hip-Hop, Rock, Dance, Relax, Concentrazione…); one tap searches it.
  - **La tua libreria**: edge to edge on black, with large square tiles for Preferiti, Download, Cronologia, File locali and Podcast and the number of songs under each name.
  - **Albums and playlists**: the title, the artist and the details on the left under the cover, and the round green play button with shuffle beside it.
  - **The player**: from the cover's colour down to black, a white play button, shuffle and repeat in green with a dot, the favourite as a green tick.
- On the Mac the classic style makes the app dark and green and flattens the pages; the sidebar and the player bar stay as they are.

## 1.34.3 (2026-11-12)

### Fixed
- **Your own songs said "Video non disponibile" and didn't play.** When the app didn't find a song's file at that moment (a folder chosen with the Files picker whose access had to be opened again, a file in iCloud not on the device yet), it didn't treat the song as one of yours and asked YouTube for it, which answered "Video non disponibile": the real cause was hidden and the song could never play. Now your songs never go to YouTube; before one plays, its folder is opened again if needed and the file is read through iOS's file coordination, which brings it down from iCloud or a cloud app (Google Drive, OneDrive…); if it still can't be opened, the message names the file.
- **Songs in iCloud Drive not on the iPhone yet are found.** iCloud keeps a hidden stand-in for them, which the list left out: they are now asked for, Library › File locali says how many are on their way ("Download da iCloud"), and they appear when they arrive. The folders are read the way Apple asks for folders from the Files picker.
- **Songs copied into a folder while Seaglass is open appear.** The folders were read once per launch: now whenever the page opens and when the app comes back.

## 1.34.2 (2026-11-12)

### Fixed
- **A song of your own that AVPlayer wouldn't open ("Video non disponibile") now plays.** iOS reads a file through a system service of its own, which refuses some files that the app itself can read: with no video, no cover, or an unusual container. When that happens, Seaglass decodes the song itself (audio only, in this app, which holds the access to your folder) into a PCM copy in its cache, and plays the copy. If the file can't be decoded either, the message now ends with the numbers of the error (for example `AVFoundationErrorDomain -11828`), so the cause can be told.

## 1.34.1 (2026-11-12)

### Added
- **Seaglass's own Musica folder** (iPhone and iPad). Files shows it as **Sul mio iPhone › Seaglass › Musica**: songs copied there with Files are read by the app with no picker and no permission, and appear in Library › File locali, always the first folder of the list (it can't be removed). It is the way in that doesn't depend on the access the Files picker hands over.
- **Aggiungi file…** in Library › File locali: the Files picker for audio files, which the system copies for the app (no access to where they are is needed); they are moved into the Musica folder and read.

### Changed
- A folder with no songs in it says so ("Nessun brano trovato"), and the page explains the Musica folder.

## 1.34.0 (2026-11-11)

### Changed
- **The playlists' Mix is a Premium feature of its own** (iPhone, iPad and Mac). The transitions designed between the songs of a downloaded playlist (**Mix delle playlist**) now have their own line among what Premium unlocks, in the app and on the account page, and the explanation of Premium opens on it when the Mix is used without Premium. (It was locked together with AutoMix before, and still is where Premium can be bought and there is none.)
- **AutoMix and the playlists' Mix are marked as beta features.** A **Beta** label stands beside their names: in Settings › Riproduzione (the choice of transitions and the AutoMix section), the queue's AutoMix switch, the playlist's Mix buttons and the Mix editor, and the list of what Premium unlocks; and on the account page, the README, the AltStore source and the documentation. On Android, Settings › Riproduzione names it "AutoMix · Beta" (0.4.3).

### Fixed
- **Choosing a folder for the local files did nothing.** In Files' picker, "Apri" didn't answer: the picker of SwiftUI stops working when another one is in the same page (the Library has one, for importing playlists). The folder is now chosen with Files' own picker, and a folder that can't be opened says so instead of staying silent.

## 1.33.0 (2026-11-11)

### Added
- **Your own songs, from a folder on the device** (iPhone, iPad and Mac). **Library › File locali** takes a folder you choose (in Files, iCloud Drive, a USB drive) and lists the MP3, M4A, AAC, FLAC, WAV, AIFF and CAF files in it and its subfolders as songs, with their title, artist, album, length and cover read from their tags (the file's name stands in for a missing title). The songs play from where they are: Seaglass never copies, changes or deletes them, and removing a folder only makes the app forget it. They queue, join the favourites and the playlists, mix with AutoMix, sing along with the karaoke and have lyrics as any song does, and the search shows the ones that match first, under **Sul dispositivo**, with no network. A folder is read again when the page is opened for the first time since the app started and with **Aggiorna**, and only the files that are new or changed are read again. Files that are in iCloud Drive but not downloaded yet have to be downloaded in Files first. These songs stay on the device: they aren't synced to the account, have no YouTube radio, and aren't downloaded or shared.

### Changed
- **The search's history works as the other song lists.** A song in it is a row like any other: swipe it right to add it to the queue, left for the favourites or to take it out of the history, and hold it for its menu. An artist, an album, a playlist or a search in the history are taken out by a swipe left, or held.

## 1.32.0 (2026-11-11)

### Added
- **AutoMix live** (iPhone, iPad and Mac). AutoMix can now mix the next song live, the way a DJ does with two decks, instead of preparing the transition as a file.
  - The next song plays on a second player that is loaded well ahead (15 to 30 seconds before the transition). It starts silently just before the transition, in step with the playing song, and is corrected only while it is still quiet in the mix.
  - During the transition, each song's level, bass, middle, top and filters move as the plan says, by the time of the music itself, so the headphones' or speaker's delay doesn't matter.
  - Each transition is chosen from the two songs' analyses. AutoMix first tries a beat-matched mix over 16 bars on a phrase, then over 8, 4 or 2 bars. If none fits, it tries a filtered fade, then a cut on the beat, then a short fade, and otherwise plays one song after the other. A candidate that would need a speed change of more than 8 %, put beats more than 20 ms apart, sing two voices together, or leave out too much of the song is refused, whatever its score.
  - The next song plays at its own speed and with its own sound from its first note, so nothing changes once the mix is over: for a beat-matched mix it is the song that is ending which takes the new tempo, gliding there over the bars before the mix in steps of at most half a percent a bar, too small to hear. Each step is a fresh player of the song at the next speed, taking over on a downbeat (an 80 ms crossover between two copies of the same music); changing a playing song's speed can be heard (the sound jumps), so a heard player's speed never changes. The next transition is prepared once the mix is over, so the analysis doesn't compete with the two players.
  - If anything isn't ready in time, the transition becomes a plain fade or the mix prepared as a file, as before. If the next song stalls or drifts while both are heard, the effects ramp back out and the song carries on.
  - **Beats from a neural beat tracker.** The bars, phrases and stretches AutoMix mixes on come from Beat This! (JKU Linz, MIT licence), run on the device with Core ML when a song is analysed, as Myspoti's Segue does. Seaglass's own analysis found the tempo but rarely a stretch steady enough to beat-match on real songs, so mixes stopped at a filtered fade.
  - **Mix length:** Breve (up to 8 bars), Normale (up to 16) or Lunga (up to 32, when both songs hold their beat that long), with shorter or longer fades to match.
  - **Automatic equaliser:** bass, mids, highs, filters and an echo on the beat pass from one song to the other; turned off, only the volumes move.
  - **Echo:** in some mixes the outgoing song's last beats are thrown into an echo on its beat, which rings on over the next song.
  - **Where the next song comes in.** It can come in where it really starts, not always at its very beginning: after a quiet intro, on a section start or where it arrives after the mix, up to a minute in (never past a third of it). Up to 30 seconds of its start can be left out this way without counting against the mix; a quiet intro the mix spans, with the song arriving right after it, is still played as a DJ would.
  - Settings shows the last choice and why the more ambitious levels weren't used. **Settings › Riproduzione › Mix dal vivo** turns it off (back to the prepared mixes); its length and equaliser are under it.
- **The mix on the progress bar** (iPhone, iPad, and the full player on a Mac). Less than a minute before the transition into the next song, the player's progress bar shows where it will happen: the live mix, the prepared mix or the crossfade. **Settings › Riproduzione › Segna il mix sulla barra** turns it off.
- **Recent searches with their covers** (iPhone, iPad and Mac). What you pick from the results (a song, an artist, an album, a playlist) is kept in the search's history with its cover, round for an artist; a tap plays the song or opens the page. Searches sent without picking anything stay, with a magnifying glass.

### Changed
- **The "Massima" download quality is called "Opus 160 kbps (~5 MB/min)"** instead of "lossless da Opus": the file keeps YouTube's Opus as it was decoded, and was never lossless audio.
- **The karaoke's voice slider works as Apple Music's Sing** (iPhone and iPad). Dragged down, the voice gets softer all the way and is gone at the bottom; up, it comes back. Its volume follows a loudness curve (half way down is 18 dB softer), so the whole travel is heard, and it moves smoothly while the song plays, without clicks. The karaoke stays on while you drag (at the top the voice is whole); a tap turns it off. The drag no longer gets taken by the lyrics' scrolling.
- **Search results while you type.** The songs show as soon as they arrive, a moment after you stop typing, without waiting for the playlists and artists or for the return key; the previous results stay until then, instead of "no results".

### Fixed
- **The queue's AutoMix and Radio card** had broken corners: its glass was cut by the list's square edges. It is now a translucent card like the songs' rows.
- **No more silence after going back in a song a live mix brought in.** Moved back to before where the mix began, or back to its start during the mix, the song went on without a sound: its mix was still holding it silent there. Its sound now goes back to plain once the mix is over, and a mix still to come starts over from where the song was moved to.
- **Last.fm's lists in the queue** (Top Last.fm, Taste Mix, Riscopri, recognized songs): the next five songs are looked up on YouTube Music ahead, not only when they play, so the queue shows their covers and AutoMix can mix into them instead of saying "Non disponibile per questi brani".
- **Tempo no longer freezes streamed songs.** With Tempo away from 0, a song that wasn't downloaded could stop loading for good, even after resetting Tempo: YouTube's stream comes in at about the song's own speed, slower than a sped-up song plays. Now the song's copy on the device takes over as soon as it is there. A song that stays stuck for 8 seconds gets a fresh stream, once, and then plays with what has arrived. Measuring the BPM no longer competes with playback.

### What still has to be checked
- AutoMix live was listened to on an iPhone and on a Mac; AirPlay's timing and the tuning on more genres still need listening. The automatic checks run on songs made for them, on the build Mac.

## 1.31.4 (2026-11-10)

### Fixed
- **Mac: a bigger sidebar.** Its names, symbols and playlist covers are larger and easier to see, with more room between them.
- **Mac: the sidebar's top.** No line runs under the window's buttons any more, and the list doesn't scroll under them.
- **Mac: the Home follows the colours of the song playing**, as the other pages do.
- **Mac: the volume slider drags smoothly.** Each step of a drag saved the volume, and every save woke what watches the preferences; it is now saved once the slider stops.

## 1.31.3 (2026-11-10)

### Fixed
- **Mac: the sidebar is Liquid Glass**, as Apple Music's on macOS 26: a glass panel floating inside the window, tinted by the theme's colour, with the window's buttons on it, the library and the playlists in sections that fold, and Settings at its foot. The system's sidebar was opaque in Seaglass.
- **Mac: the zoom works.** It now makes the whole window bigger or smaller, text, buttons, covers and spacing together, as Spotify's zoom does; before, it changed nothing. It applies at once, from **Settings › Appearance › Zoom** or with ⌘+, ⌘− and ⌘0.

## 1.31.2 (2026-11-10)

### Added
- **iPhone and iPad: karaoke as Apple Music's Sing.** With the lyrics open, a slider beside them sets how much of the voice is left: down takes it away, up brings it back. A tap turns the karaoke on (without the voice) or off, and holding it offers the voice alone. It replaces the karaoke button under the player for songs; podcasts keep their speed there.
- **Mac: zoom.** **Settings › Appearance › Zoom** makes text, and the controls sized with it, smaller or larger, from 75 % to 150 %, as Spotify's zoom does. **View › Zoom In** (⌘+), **Zoom Out** (⌘−) and **Actual Size** (⌘0) change it too.

### Changed
- **Mac: the system's sidebar, in Liquid Glass**, with search at the top, Home, the library (Library, Favourites, History, Downloads, Podcasts), each playlist with its cover, and Settings.
- **Mac: a larger player bar**, as in Apple Music, floating in glass at the bottom of every page, playlists opened from the library included, with the page scrolling under it.

### Fixed
- **Tempo shows the song's BPM again** (iPhone, iPad and Mac). It showed it only for songs on a perfectly steady beat, which left about half of real songs (played freely, live, swung) without a number though their tempo was measured right. Now any song whose beat is followed shows its BPM.
- **Mac: the volume slider no longer drags the window.** Dragging the slider moved the whole window at times: the window now moves only by its title bar, and the slider is the Mac's own.
- **Mac: AirPlay's list opens by its button.** It opened far up and to the left of it.
- **Mac: the player bar inside playlists.** A playlist opened from the library hid the player bar.

## 1.30.1 (2026-11-10)

### Fixed
- **Mac: the account stays signed in.** After signing in, the Mac's keychain refused to keep the session, so Settings › Account showed no name, email or plan and nothing synced. The session is now kept in the Mac's login keychain, and the account shows and syncs as on iPhone. Last.fm's sign-in on Mac had the same problem and is fixed too.
- **Mac: the player bar is Liquid Glass again**, floating at the bottom of the page as in Apple Music, with the page scrolling under it. The sidebar keeps the playlists' covers.
- **Mac: Install and restart closes everything.** Every open sheet and alert closes before Seaglass quits to install the update; with one still open, the app used to stay as it was instead of restarting.

## 1.30.0 (2026-11-10)

### Added
- **Seaglass account** (iPhone, iPad and Mac). **Settings › Account** signs in to a Seaglass account, or creates one, through its web page. Favourites, playlists (their names and songs), the listening history and listening preferences (audio quality, transitions, lyrics, appearance) are then the same on every device signed in: what one device adds or removes, the others do too, and when two devices change the same playlist both changes are kept. Downloads, playlist covers and Mixes stay on each device; signing out keeps the library on the device. As on Spotify, the app only shows the account (name, email, plan, last sync): the name, the password, the subscription and deleting the account are on the account page, which **Manage account** opens already signed in. New passwords need at least 8 characters, one of them special; the page shows how strong a password is as it's typed, and whether the two match.
- **Seaglass Premium**, a subscription on Patreon linked on the account page. Premium unlocks AutoMix (and playlists' Mixes), importing playlists from links (Spotify, Apple Music, YouTube), song recognition, lyrics translation, AI karaoke and Tempo; without it they show what Premium is and lead to the account page, as Spotify's app does, and AutoMix's transitions become crossfades. Listening, the library, crossfades, downloads and importing playlists from files stay free. Premium is checked when the app opens and keeps working offline for 30 days.

- **Help and a forgotten password.** The account page emails a six-digit code to choose a new password, and **Settings › Account › Write to support** writes to Seaglass's support by email.

The account and Premium are available in builds that know the account service (see `server/account/README.md`); where Premium can't be bought there (no Patreon set up), its features stay unlocked. The Android app has no accounts yet, and its features are unchanged.

## 1.29.1 (2026-11-09)

### Fixed
- **A recognized song's radio.** Playing a song found by recognition now fills the queue with its radio of similar songs, as any song does. A song known only by its title and artist (recognized, or from Last.fm) had no radio until it was found on YouTube Music, so the queue stayed empty.
- **The queue's layout when it's empty.** Its "The queue is empty" message sits below the header. In the iPhone's short panel it used to cover the header and the Shuffle button.
- **Mac: recognizing a song more than once.** After the first time, especially with a song playing, recognition stopped as soon as it started: switching to the microphone changes the audio output, and that counted as losing the microphone. Now only the microphone really going away stops it.

### Added
- **Settings › Audio › Volume in the player** (iPhone and iPad) shows or hides the volume bar under the player's controls. A Mac's player always has its volume.

## 1.29.0 (2026-11-09)

### Added
- **Recognize a song on iPhone, iPad and Mac.** The button in Home and Search opens an animated listening panel. With microphone permission, Seaglass records a short sample, computes an audio fingerprint on the device and looks it up through Shazam's community endpoint, without API keys or paid services. The result shows the cover and song metadata, with actions to play, favorite, download or add it to an existing playlist. Recording stops on cancellation, closing the panel, backgrounding or an interruption. This is an unofficial integration; service errors and rate limits stop the request without automatic retries.

### Changed
- **Mac: a larger player that follows the window.** The cover and controls use the available space, and lyrics and queue text scale with the panel. The sidebar shows each playlist's artwork.
- **Mac: Seaglass's own volume.** The sliders control only this app, including AutoMix, crossfades and karaoke, keep their level between launches, and work with HDMI and USB outputs too.
- **Mac: visible, cancellable update downloads.** A progress bar shows the transfer, with an option to cancel. Seaglass checks and prepares the update automatically, then asks before restarting. Choosing later keeps it ready to install when the app quits. Restarting exits the whole app, including its menu bar and background playback.

### Fixed
- **Mac: the player closes reliably.** Its close button sits below the titlebar, away from the window controls, and dismisses the player even if Catalyst drops an animation completion.

The player layout, volume and updater changes apply to Mac; song recognition is shared with iPhone and iPad.

## 1.28.1 (2026-11-09)

### Fixed
- **Mac: the space bar plays or pauses** anywhere in Seaglass, as in Apple Music, not only in the player. While you type (search, a playlist's name), it's a space.
- **Mac: the volume bar works**, in the player and in the player bar. A click sets the volume and a drag follows the pointer: the system's slider lost its drags to the glass around it. An output with no overall volume has each of its channels set instead.

## 1.28.0 (2026-11-09)

### Changed
- **Mac: laid out as Apple Music.**
  - **Sidebar:** Search at the top with the Home and Settings, then the library (Library, Favorites, History, Downloads, Podcasts) and every one of your playlists.
  - **Player bar:** along the bottom of the window, as Apple Music's. It has shuffle, back, play, forward and repeat, the song with its progress (a click opens the player), the lyrics, the queue, AirPlay and the volume.
  - **Player:** the cover, the song and its controls are in the middle, with "Artist — Album", the favorite button and the ⋯ menu. The rest sits in glass at the corners: closing at the top left; AirPlay and the volume at the top right; karaoke, tempo, lyrics and queue at the bottom right. The lyrics and the queue open beside the player.
  - **Home:** on the window's own background.
- **Mac: the queue as on the iPhone**, from the player bar or the player: automatic radio (∞) carries on with similar songs once the queue ends, AutoMix, and shuffle over the whole playlist.

Nothing changes on iPhone and iPad.

## 1.27.0 (2026-11-09)

### Added
- **Volume bar in the player**, under the controls, as in Apple Music. On iPhone and iPad it's the system's volume and follows the buttons. On a Mac it's the volume of the sound output, the same as in the menu bar, and follows the keyboard's keys. It's dimmed for an output with no volume to set.
- **Mac: Seaglass in the menu bar.** Its note sits in the menu bar while the app is open, even with the window closed, so you can see it's still there. Its menu shows the song playing, with play or pause, next and previous, opening the window again, and quitting.
- **Mac: automatic updates.** A new version downloads and installs by itself, with no zip to open and no "Open Anyway". It installs right away if nothing is playing, otherwise when you quit Seaglass, and Seaglass opens again on the new version. Settings › Updates can also install it now ("Install and relaunch"), or only tell you about it. Before installing, the download is checked against GitHub's (size and SHA-256), and the app inside must be Seaglass, at that version, with a valid signature. Seaglass must be in the Applications folder to update itself. This first time, 1.27.0 still has to be downloaded by hand.

### Changed
- **The tempo's BPM shows sooner.** With the tempo changed, each song's BPM is measured as it starts, so it's there when the tempo panel opens. It's measured from the file already playing, instead of downloading the song again, and ahead of other work. While it's measured, the panel shows a spinner.

## 1.26.1 (2026-11-09)

### Fixed
- **Mac: the music keeps playing with the window closed**, as with Apple Music: closing the window no longer quits Seaglass. It stays open in the Dock and the menu bar, its Dock icon opens the window again, and ⌘Q quits it. With the window closed or minimised it also goes on preparing what comes next (AutoMix's mixes, the karaoke, the songs' best quality), as with it open.
- **Mac: the player's corners** match the window's. They were rounded as an iPhone's screen, more than a Mac window, and left the app showing at the corners.

### Changed
- **Mac: the Home is laid out as Apple Music's**: big cards for the daily mixes, with the title on the cover's own colours; square covers for the songs played lately and the quick access; the moods as coloured cards; and rows that scroll a page at a time with the arrows at their ends, under the pointer. A play button shows on the cover under the pointer.

Nothing changes on iPhone and iPad.

## 1.26.0 (2026-11-09)

### Added
- **Seaglass for Mac**, for Macs with Apple silicon (M1 or later) and macOS 26 Tahoe or later: the same app as on the iPad, with its Liquid Glass design, in a window of its own, with every feature: AutoMix, the tempo fader and key lock, the AI karaoke, the equalizer, lyrics and their translation, downloads, podcasts, Last.fm, playlists and the library. The keyboard's media keys and Now Playing in Control Center control the music; ⌘→ and ⌘← skip, and the space bar plays or pauses in the player. Download `Seaglass-mac.zip` from the release, open it and drag Seaglass to Applications; the first time, allow it in System Settings › Privacy & Security ("Open Anyway"), since it isn't signed by an Apple developer account. On a Mac, updates download in the browser, and Last.fm is connected in the browser too.

## 1.25.2 (2026-11-09)

### Fixed
- **Shuffle takes the whole playlist.** A song chosen near the end of a playlist, and shuffle turned on afterwards, shuffled only the few songs after it: shuffle now brings back every song of the queue not played yet, those before it too, as Spotify and Apple Music do. (A song chosen with shuffle already on was played with all the others shuffled after it, and still is.)

## 1.25.1 (2026-11-09)

### Fixed
- **The lock screen's time follows the song.** On iOS 27 the lock screen and the Dynamic Island move the song's position on by themselves at normal speed: with the tempo changed it ran ahead of the song, and after some moves (a new song, a jump) it could stay well off it. The app now checks it while the song plays and sends the position again as soon as it strays by more than three quarters of a second.

## 1.25.0 (2026-11-08)

### Added
- **Tempo fader**, laid out as in a DJ app (djay Pro's): the metronome button in the player opens an upright fader with notches that makes songs up to 15% faster or slower (up for slower, down for faster, as on a turntable), with − and + to nudge by 0.1% and the dot beside it to go back to 0. Above it, the song's tempo in BPM once AutoMix's analysis has measured it, and the change in percent, whose arrow sets the fader's range: ±8%, ±15%, ±25% or ±50%. The tempo stays for every song until it's reset; podcasts keep their own speed.
- **Key lock**, the note beside the fader: on (the default), voices keep their pitch at any tempo; off, the pitch moves with the tempo as on a turntable, higher when faster and lower when slower.
- While the tempo is changed, AutoMix and the crossfade pause and songs follow each other without a mix; at 0 they come back.

### Fixed
- **Songs added to the queue play next.** "Add to queue" put a song at the very end, after the rest of the album, playlist or radio: it now goes right after the song playing and after the songs added before it, in the order they were added, as in Spotify's queue ("Play next" still puts it first). Shuffle leaves the added songs where they are.

## 1.24.0 (2026-11-04)

### Added
- **Nine more languages.** Seaglass is now also in French, Spanish, German, Portuguese, Chinese (Simplified), Japanese, Russian, Turkish and Arabic, besides English and Italian. It follows the device's language; Settings → Language changes it for Seaglass only. In Arabic the app reads right to left, while the player's timeline, its controls, the equalizer and the Mix editor keep running left to right, as in Apple's apps.

### Changed
- **Simpler Settings.** A short list of topics, each opening its own page: Audio, Playback, Lyrics, Appearance, Language, Last.fm, Storage, Updates and About. Each page keeps one line of explanation at most; the long notes are gone. The technical details (crash reports, start times, the last AutoMix choice, the karaoke model) moved to About → Diagnostics, and the saved karaoke tracks to Storage.
- Lyrics translation defaults to the device's language for Portuguese and Chinese too.

### For development
- The localization check covers every language: each needs exactly the English keys, with the same format specifiers. CI also takes screenshots in Arabic, Japanese and German.

## 1.23.1 (2026-11-03)

### Changed
- **ProMotion on iPhone.** On iPhones with a 120 Hz display, the app's own animations (the player card opening and closing, the lyrics and queue panels, the other transitions) can now run at up to 120 Hz, not only scrolling. An iPad Pro already used it. The display still slows down when nothing moves.

## 1.23.0 (2026-11-03)

### Added
- **Seaglass on iPad.** The app is now universal: the same IPA installs on iPhone and iPad (iPadOS 26 or later), as the same app with its own library on each device. On an iPad it turns to every orientation and opens in resizable windows.
  - Tabs at the top that can become a sidebar, as in the Music app.
  - The player keeps an iPhone's proportions, centred; in landscape, the lyrics (or an episode's chapters) and the queue open beside the cover instead of in its place.
  - Home shows three shortcuts and four moods to a row; album, playlist and podcast pages keep a readable width.
  - With a keyboard: ⌘→ and ⌘← skip songs, and in the player the space bar plays or pauses.

### For development
- CI also takes screenshots on a 13-inch iPad Pro, in portrait and landscape.

## 1.22.2 (2026-11-01)

### Fixed
- **The app icon showed only its top half.** The icon file of 1.22.1 (and the disc of 1.21.1) was damaged when it was saved: past its first 448 rows a block of the image was missing, so iOS, AltStore and GitHub drew the top of the note and nothing below. The icon is rebuilt whole from the same artwork (the note of the README's banner, placed and lit as in the original), and every build now checks that the repository's images are intact.

## 1.22.1 (2026-11-01)

### Changed
- A redesigned musical-note app icon and matching GitHub and AltStore artwork.

## 1.22.0 (2026-11-01)

### Added
- **Podcasts**, from YouTube Music's catalogue, in Library → Podcast:
  - **Continue listening**: the episodes you've started, with how much is left. Each episode starts again from where you stopped (a few seconds earlier), and one you finish is marked as played.
  - **Following**: follow a show from its page; the shows you follow are kept on the iPhone, no account needed.
  - YouTube Music's suggestions, shows **by topic**, and a search for shows and single episodes. Podcasts also appear in the main search, after albums.
  - A show's page lists its episodes, newest first, loading older ones as you scroll; a show's description, "Resume" or "Latest episode", and "Follow".
- **In the player, for an episode**: back 15 seconds and forward 30 seconds (also on the Lock Screen), a speed from 0.5× to 2× (kept between episodes; songs always play at 1×), and, in place of the lyrics, the episode's **chapters** (from the timestamps in its description; tap one to jump there) and its description with working links.
- Episodes can be queued, downloaded, shared and marked as played or unplayed from their menu.

### Changed
- Episodes stay out of AutoMix, crossfades, karaoke, Last.fm scrobbling, the listening history and the recommendations, and no radio of songs starts after an episode ends. The exact length of an episode is fetched when it starts (the lists round it to the minute).

## 1.21.1 (2026-10-31)

### Changed
- A new iridescent disc app icon and matching artwork for the GitHub page and AltStore source.

## 1.21.0 (2026-10-29)

### Improved
- **Playlist import.** The app keeps a report of songs it couldn't match, searches that failed, unavailable entries and duplicates. Open the report after importing or from the playlist later, and choose a suggested YouTube Music recording for a missing song. A chosen alternative is placed near its original neighbors.
- **Long Spotify playlists.** Public Spotify links may expose only their first 100 entries; the app now warns when the list may be incomplete. To import a longer list, choose a Spotify account-data playlist JSON file or a CSV containing song titles and artists in Library → Import playlist from file. The file is read on the device; song searches still use YouTube Music.
- Matching tries a second search when needed and checks the title, artist, duration and recognizable versions such as live and remix before adding a result automatically.

## 1.20.0 (2026-10-29)

### Improved
- **AutoMix: more beat-matched transitions.** The planner now gives a safe mix in time priority when its quality is close to the best alternative. It can bring songs with a wider difference in tempo together, changing each song's speed gradually while keeping its pitch, and can use a steady part of a song even when its overall beat grid is less reliable. It still avoids forcing incompatible or unsteady rhythms and excessive vocal overlap.
- After a beat-matched mix, the incoming song spends a little longer at its original tempo before playback returns to the original file. The return point is matched over a longer stretch when the usual comparison is unclear.

## 1.19.1 (2026-10-29)

### Changed
- **AutoMix audio.** Restores the playback handover used in 1.15: the mix fades in immediately and the outgoing player fades out with its volume. When the equalizer is off, the mix no longer has an audio-processing tap solely for the handover. This addresses a possible cause of silence on iPhone; it still needs listening on the affected device. A brief volume dip at the change of players may return.
- Checks the beginning and end of the saved mix against the renderer's output. If either loses nearly all its sound, the app uses a simple crossfade instead of handing over to a damaged mix.

## 1.19.0 (2026-10-29)

### Improved
- **AutoMix volume and bass.** The bass now passes between the songs more smoothly, and the planner estimates the sound of its filters using the songs' measured spectrum, including deep bass and high frequencies. Its level controls release earlier where they are no longer needed, reducing unnecessary dips.
- **Short transitions.** A brief gapless or sequential transition fades the two songs through the crossing rather than starting both at full volume. Harmonically incompatible songs are given more weight when choosing a transition.
- The song analysis is refreshed once to use the new measurements. Settings → Diagnostics records the latest AutoMix level checks.

### For development
- AutoMix checks cover partial loudness windows, the full-spectrum estimate, the bass swap, short transitions and equalizer settings. The iOS build and the real-song render workflow passed. Some real-song estimates still differ from the rendered level, so the result should also be checked by listening on an iPhone.

## 1.18.2 (2026-10-28)

### Fixed
- **No sound during AutoMix's mixes in 1.18.1.** 1.18.1 saved the rendered mix as 32-bit floating point (to keep the songs' peaks over full scale), and on the iPhone the mix was heard as silence: from the handover to where the next song carries on by itself, nothing. The mix is saved as 16-bit again, with the limiter of 1.18.0, as up to 1.18.0 (measured on real songs, it takes over within 0.06 dB of the song's level). The shorter, quieter crossing of 1.18.1 stays. The render check now makes sure the mix stays 16-bit.

## 1.18.1 (2026-10-28)

### Fixed
- **AutoMix: the volume dipping for a moment as the mix takes over.** At the handover the song and the mix (which starts as a copy of it) crossed over a quarter of a second, each in its own player. Two players are never on the very same sample, and the same music a few milliseconds apart, half and half, partly cancels out: on 8 pairs of real songs, with the players 1, 2 or 5 ms apart, the volume dipped for a moment by about 2 dB, up to 6.4. They now cross over 40 ms, at the quietest moment of the mix's first second (between the beats rather than on a kick): about 0.3 dB, at most 0.9 (the quietest tenth of a second against the song's). Songs that fade out with the player's volume (Dolby, or one started before AutoMix was turned on) still cross over a quarter of a second, as their timing is looser.

### Changed
- The mix's limiter now works only where both songs play together, and the mix is saved as floating point: where one song plays alone the mix is exactly that song, its peaks included. Measured on 8 pairs of real songs, at full volume and 6 dB down, the mix takes over within 0.06 dB of the song and hands the next one back within 0.01 dB.
- Settings → Informazioni → "Ultima scelta AutoMix" also shows the "Volume uniforme" of the two songs (how much each is turned down), and "Ultimo passaggio AutoMix" still shows how far apart the two players started ("scarto"): if a jump in volume is still heard at a transition, those two say where it comes from.

## 1.18.0 (2026-10-28)

### Changed
- **Onda is now Seaglass.** A new name, in English: sea glass is glass smoothed by the waves. It is the same app: it installs over Onda and keeps your library, downloads, playlists, Mixes and settings (its identifier and data are unchanged). In the Files app its folder is now called Seaglass, and the IPA is `Seaglass.ipa`.
- **Search: songs first.** Results start with the songs (the first six; "Mostra tutti i brani" shows the rest), then playlists, then artists and albums. When what you type is an artist's name (give or take capitals, accents, spaces and punctuation: "ac dc" is AC/DC), that artist comes first.
- **AutoMix up to 40 seconds from the ends.** It can now finish the mix up to 40 seconds before the end of the song playing (leaving its outro out) and start the next song up to 40 seconds in (leaving its intro out). These are weighed with the others, on phrases where a section starts, and chosen when they sound better: a quieter or longer ending, a long intro. Leaving loud music out still costs a little, and leaving words out a lot.
- Two songs at full together for long now costs too (two whole arrangements at once), so a long mix brings the next song's main part in as the first one leaves; and the next song's voice is kept from coming in over the first one while that is still up.
- Phrases are counted from the start of each section (where the harmony and the loudness change), so an intro of odd length doesn't shift them.
- Choosing among the candidates (now up to about 1,700 for two four-minute songs) runs away from the main thread.

### Added
- **Mix from the playlist's page.** Under "Riproduci" and "Casuale", "Attiva il Mix" turns the playlist's Mix on (or off) in one tap, and "Transizioni" opens its transitions. With the Mix on, every song of the playlist is mixed into the next when you listen to it, even with AutoMix off: with the transitions you designed, and with AutoMix's choice for the others.
- **Reorder a playlist's songs.** "Riordina i brani" in the playlist's ··· menu shows a handle on each song: drag it up or down (or tap the red button to remove it), then "Fine". Holding a song opens its menu, which is why dragging it didn't work.
- **Playlists in search**, from YouTube Music's playlist search, in a row after the songs.

### Fixed
- **Artists in search didn't open.** Tapping an artist (or an album) in the search results could do nothing: the tap that saves the search to "Ricerche recenti" could keep the link from opening. Results are now buttons that save the search and open the page. And an artist page opened from a song whose channel isn't an artist's page now looks the artist up by name instead of failing.
- **AutoMix: kicks on kicks when both songs change tempo.** Time stretching moves high, short sounds (hi-hats) differently from low ones, more so when both songs are stretched (each by a few per cent, meeting halfway): the mix lined up all onsets and could leave the kick drums some 18 ms apart. It now lines up the low ones (kick and bass) as a DJ does, within 80 ms either way, and all onsets only when the low ones don't line up clearly.
- **Playlist Mixes that didn't play:**
  - The Mix could only be turned on once every song of the playlist was downloaded: with a single song missing, the switch stayed grey. Now it turns on for any playlist; songs not downloaded are mixed as AutoMix mixes them, from the copy streamed anyway. Designing a transition still needs its two songs downloaded (they are analysed from their files), and only those transitions are greyed out.
  - After the app was closed and opened again, the queue came back without knowing which playlist it was playing, so its Mix no longer played. The queue now remembers it.
  - In 1.17.0, two songs of the same album one after the other in a playlist were played as on the album, without mixing. That now happens only when an album is played in order, not in a playlist.

## 1.17.0 (2026-10-28)

### Changed
- **AutoMix chooses each transition instead of taking the longest that fits.** Up to 1.16 it always tried 16, then 8, then 4 bars of beat-matched mix, with both songs' tempos meeting halfway up to 30 % apart. Now, for each pair of songs, it builds many candidates and weighs them, without rendering any, from what it knows of the two songs where they would actually play together:
  - the candidates: beats matched over 2, 4, 8 or 16 bars (at the tempo of the song playing, of the next one, or meeting between), crossfades of 2 to 12 seconds at the songs' own tempos, the next song coming in during a fade-out, the next song starting as this one's sound ends (the silence left out), or one after the other with a short breath;
  - what each costs: beats that drift off the grid in that stretch (live and freely played songs), two beats heard together without being matched, keys that clash (the more the longer and the more melodic the overlap), two voices singing at once, a phrase faded or cut, the next song's first words buried or left out, jumps and holes in the loudness, how much the tempo changes and whether a voice is heard meanwhile, a mix that doesn't start or end on a phrase, and loud music of either song left out;
  - a long transition is played only when it is better: every risk grows with the overlap, and a length other than eight bars (or four seconds for a crossfade) costs a little, so that equally good candidates don't simply default to the longest or the shortest. When nothing is good enough, a three-second crossfade.
- **Voices.** Before choosing, AutoMix looks for where the two songs are sung near where they meet (the last minute of the song playing, the first 45 seconds of the next) with the karaoke's vocal model, which is trained on singing in music. On 40 Creative Commons songs with every sung word timed by hand, it agreed with the timed phrases 91 % of the time (precision 0.93, recall 0.92); it found where each song's first words start within a quarter of a second in 80 % of the songs (median 0.12 s) and where the last phrase ends within a second in 80 % (median 0.4 s). So a song that ends its phrase lets the next one's instrumental bars come in under its end, the next voice arriving after it has gone; two songs sung right up to the junction aren't laid over each other. Each stretch is measured once per song and kept. It needs the energy for it (not in Low Power Mode or with a hot iPhone) and the time (it gives up a minute and a half before the song's end); without it AutoMix plans as if voices could be anywhere, which keeps overlaps short.
- **Tempo.** Each song's tempo changes by 5 % at most (it was up to 15 %); further apart, the songs are crossfaded at their own tempos. The song whose voice is heard keeps its tempo and the other adapts to it; with no voice on either side they meet halfway.
- **Volumes.** Crossfades are equal-power over the same stretch: until now the next song was at full volume half way through while the first was still at 71 %, 1.76 dB louder than either. Where both songs play at full, their levels (measured in the analysis, with "Volume uniforme") hold them down so that together they are never louder than the louder alone, the song leaving only going down and the next only up, so neither pumps and the limiter has less to do.
- **Bass and filters.** The bass passes from one song to the other, gradually over a bar, only when both are carried by it; the song leaving thins out with a high-pass only when it is. Acoustic songs are no longer cut.
- **Albums.** Two songs that follow each other on their album, played in order without shuffle, are played as the album has them: the first to its last sample, the next from its first, nothing faded or left out.
- Settings → Diagnostica shows the last choice: the candidate played with its cost and main problems, how many were weighed, whether the voices were measured, and why the best of the other kinds weren't chosen.
- Playlist Mixes are unchanged: they still start from the timing of up to 1.16.
- The analyses are made again (version 2): they now also hold each beat's share of bass, how far each beat's onset is from the grid, and each bar's harmony.

### Measured on real songs
Eight pairs of Creative Commons songs (dance, sung pop, rap, acoustic, tempos far apart, rock, reggae and one more), rendered as 1.16 did and as now from the same files, and compared with their hand-timed lyrics (not with the voice detection):
- two voices heard at once: 8.1 s over the eight pairs with 1.16 (6.6 s in the dance pair), none now;
- the first song's words faded or left out: 14.8 s with 1.16, 7.8 s now (more in one pair, the acoustic one: 2.2 s against none);
- the next song's first words under 70 % or left out: 2.2 s with 1.16, none now.
The excerpts (X and Y in random order, for blind listening) are in the "AutoMix on real songs" workflow's artifact.

### What still has to be checked
- How it sounds: the choices follow measurable criteria, checked on test songs and on Creative Commons songs, but their weights are a starting point to tune by listening. No comparison with Apple Music has been made: its transitions can't be rendered outside an iPhone.
- The voice detection's time on an iPhone (on the build Mac it takes about 1 s per 5.8 s of music, about 20 s for a pair of songs) and how often it can't finish before the mix is due.
- Live recordings: none in the test songs. And the timed lyrics leave out backing vocals and "ooh"s, so the figures above count those as no voice.

### For development
- `Tools/AutoMixCheck` checks the choice on songs made for it, with voices given: beats matched only within 5 % per song; no two voices together when both songs are sung at the junction; the next song's instrumental bars under the end of a phrase and its words after it; the sung song's tempo kept; clashing keys kept short; no bass cut for a song light on bass; a fade-out mixed into; a long intro skipped; an album as it is; the curves never pumping, never louder together than the louder alone; the plan of up to 1.16 unchanged.
- `Tools/AutoMixRenderCheck` renders beat-matched mixes within the new tempo limit and a crossfade, and checks the voice detection's arithmetic with a stand-in for the model.
- `Tools/AutoMixRealMusic` and the "AutoMix on real songs" workflow try it on the Creative Commons songs of [JamendoLyrics](https://github.com/f90/jamendolyrics) whose licence allows derivative works: the voice detection against the timed lyrics, and representative pairs (dance, sung pop, rap, acoustic, tempos far apart, rock, reggae) rendered as 1.16 did and as now, from the same files at the same gains, as X and Y for blind listening, with a report of the choices and of the loudness.

## 1.16.0 (2026-10-28)

### Added
- **Opus from the first note.** At "Massima" (for videos without Dolby or AAC 256) and "Media", a song no longer starts in AAC with Opus only from the next listen or seek. Onda downloads the WebM in pieces, takes the Opus packets out of each piece as it arrives, decodes them on the iPhone with Apple's decoder and plays them right away while the rest comes in. The song is an ordinary player item, so seeks, AutoMix, the equalizer, the lock screen and Control Center work as before. The first half second of audio is in the first ~9 KB of the file.
  - The next song in the queue, or the one you are about to tap, has its first ~8 seconds ready: 128 KB downloaded and decoded, only on Wi-Fi that isn't metered, as for AAC until now. The rest downloads when it plays. Whole playlists are never downloaded ahead.
  - When the whole song is in, its decoded audio stays as the song's cached file: seeks, karaoke and the next listen use it.
  - With AutoMix the song after a mix plays Opus too (it was the AAC copy).
  - AAC plays instead only when Opus can't, and the reason is written next to the format: a song over 20 minutes, Low Power Mode or a hot iPhone, or a stream that fails (AAC then carries on from where the song is). "Opus dal primo suono" in Settings → Audio turns it off, back to the old way.
- **Settings → Diagnostica** shows start times by how the song started (Opus prepared, Opus with its link ready, Opus from the internet, and the AAC ways). For the last start it also shows when Opus's first byte and first decoded audio arrived and when the first audio went through the audio processing. The last fallback to AAC is listed with its reason.

### For development
- `Tools/OpusStreamCheck` (CI) encodes a test signal with Apple's Opus encoder into a WebM like YouTube's and checks:
  - the progressive parser finds the whole-file packets for pieces of 1 byte to 1 MB;
  - the PCM decoded piece by piece is the PCM of the whole-file Apple Lossless conversion;
  - the first audio's timing, and prepared and cancelled streams;
  - AVFoundation opens, plays and seeks the stream through the resource loader while the data is still arriving. Before it plays, AVFoundation reads the file's last block: the stream answers it at once with silence after the song (never heard, since the item stops at the song's end), so it doesn't wait for the whole song to be decoded.
- `Tools/OpusStartupProbe` (a live CI step that never blocks the build; also runs on a Mac) times each way of starting, from the "tap": a new song (links, then AAC or Opus), AAC and Opus with their link known, AAC and Opus prepared, and the whole-file Opus of up to 1.15. It also times a seek far ahead right after the start.
- `Tools/StartupMetricsCheck` checks the timings by source, the Opus steps and the fallbacks.

## 1.15.1 (2026-10-28)

### Fixed
- **AutoMix: no more cut where the mix takes over, also with AirPods.** In 1.15.0 the playing song faded out with the player's volume, which acts on the sound as it is made: with AirPods, which play it about a fifth of a second later, the song was still at full volume while the mix came in, and was then stopped while still loud, which was heard as a cut. Nothing checked either that the mix had really started: had it started late, the song would have gone quiet anyway. Now:
  - The mix starts silent, on the exact moment of the song. A moment later Onda checks that it is playing, in step with the song; only then, about half a second in (where the mix is still the song alone), the song fades out as the mix fades in. (Over AirPlay, where the sound is heard about two seconds later, there is no time to look: the two cross where the mix starts.) A mix that didn't get ready, didn't start or isn't in step is dropped before it is ever heard, and the song ends with a plain crossfade.
  - The song fades out inside its own audio processing, over the very quarter of a second of music the mix fades in on, so the two always add up to the song: on the iPhone's speaker, AirPods, Bluetooth or AirPlay, and however busy the iPhone is while the screen moves to the next song. The song stops only once its fade has been heard.
  - The mix is made from the very audio that plays: the song's file, or a copy of the same stream. At "Massima" it could be made from the song's decoded Opus (or its AAC 256) while the AAC stream was playing: encoded differently, its music landed some milliseconds off.
  - The mix is made at the volume the song plays with ("Volume uniforme"), and made again if that changes or the song moves to another file.
  - A song that started before AutoMix was turned on (and Dolby Digital Plus) still fades with the player's volume, now set ahead by the time the sound takes to be heard.
- Settings → Informazioni shows the last AutoMix handover: whether the mix started and how far off, the output's latency and how the song faded out, or why it fell back to a crossfade.

### For development
- `Tools/AutoMixRenderCheck` plays the handover as the player makes it: the mix silent at first, then the song through the fade in buffers of uneven sizes while the mix fades in (as loud as the song before, during and after the fade, never a gap), the fade exact, set only ahead of the music and refused when it comes too late. It can't play the two players on an iPhone: that is what the line in Settings is for.

## 1.15.0 (2026-10-28)

### Added
- **Mix: 2, 4, 8 or 16 bars, like Spotify's.** Under the waveforms a "16 barre" button opens the choice of how many bars the two songs play together (the ones the songs are too short for are greyed out). The box over the waveforms always stands for those bars.
- **Mix: lines drawn by hand.** "Personalizza" (under the waveforms, or at the top of each part's options) shows the points of the Volume, EQ, Filtra or Effetti lines over the songs: drag a point to move it, tap a line to add one, tap a point to remove it; "Ripristina" goes back to the option's shape. The ends where a song plays on its own stay fixed, so a mix always starts and ends as the songs sound, and any jump drawn is smoothed over 50 ms so it never clicks.
  - The filter line works like a DJ's filter knob: open in the middle, a high-pass when it goes up, a low-pass when it goes down, on either song.
  - The effect line is how much of the song leaving goes into its reverb or echo.
  - Choosing an option again replaces the lines drawn for that part.
- The box shows the beats of the song leaving, a stronger line at each bar.
- **Swipes on songs, like Spotify's.** Swipe a song to the right to add it to the queue, to the left to add it to your favourites; a note at the bottom of the screen says so, and tapping it ("Cambia") opens the playlists to put the song in instead. In lists you could remove songs from (a playlist, favourites, downloads, the queue), "Rimuovi" sits next to the heart. On album and artist pages the row itself slides under the finger, showing what letting go will do.

### Fixed
- **AutoMix: no more cut when the mix takes over.** The playing song and the mix are two players, and two players never start on exactly the same sample: switched at once, the change was heard as a cut. Now the two (which play the same music at that moment) overlap for a quarter of a second, one fading out as the other fades in.
- **Taking off your AirPods pauses the music.** Onda only paused when iOS gave "device unavailable" as the reason for the change, with the AirPods among a few known kinds of output; now it pauses whenever the sound moves from headphones, AirPods, a Bluetooth or AirPlay speaker or the car to the iPhone itself, whatever reason iOS gives, waiting a moment when the route is still changing. Settings → Informazioni shows the last change of output and what Onda did.
- **Mix editor: dragging a song no longer shrinks the waveforms.** Dragging the lower song used to change the length of the mix, so the whole picture zoomed out and in under the finger. Now dragging a song slides it under the box, which keeps its length: the upper song changes where it leaves, the lower one where it comes in (it can skip its first bars), in whole bars with beatmatching, and only as far as the mix can be made (dragging back moves it at once). The waveforms cover the whole songs, faded where they don't play in the mix.

### For development
- `Tools/AutoMixCheck`: every choice of bars over two-minute songs (on the beat), moving each song by whole bars (exactly that far, the same length, on the beat), moves past the ends kept where the mix can be made, lines traced from every option (sound like it, start and end right, no clicks, also over a 3.5-second overlap), the filter knob, fixed ends, and designs saved by 1.14 still read. `Tools/AutoMixRenderCheck` renders a mix with lines drawn by hand.
- New screenshot: drawing the volume lines (`-OndaScene mix:edit`). The screenshot job has 20 minutes.
- `HorizontalPan`: a sideways drag (a UIKit pan that only starts across) that leaves vertical scrolling alone.

## 1.14.0 (2026-10-27)

### Added
- **Mix for playlists, like Spotify's.** Downloaded playlists get a Mix button: turn the Mix on and design the transition between each pair of songs in an editor like Spotify's (in Liquid Glass):
  - Both songs' waveforms, overlapping in a box that stands for the time they play together, with the volume (blue), bass (yellow), filter (pink) and effect (white) curves drawn over them. Drag the lower song to make the mix longer or shorter, the upper one to move where the first song ends; with beatmatching on, in whole bars.
  - Each song's tempo (in orange when the beats can't be matched) and key in Camelot notation (8B is C major).
  - Presets: Auto, Dissolvenza, Ascendente, Sfumatura, Onda, Fusione, Passaggio brusco, Eco, Picco, Fusione calda.
  - **Volume:** smooth crossfade, overlap, fade in/fade out, cut in, cut out, center cut, plain crossfade, quick fade, one-bar fade in or overlap with a cut out.
  - **EQ:** bass swap in the middle, at the end or at the start, three-band fade, quick or long bass cut, bass fade out.
  - **Filtra:** low-pass and high-pass sweeps on the song leaving, on the song coming in or both, a half high-pass, and a noise sweep at the end.
  - **Effetti:** reverb in the middle or at the end (with a cut or fading), echo with half-beat, three-quarter or full-beat repeats (cut or fading), and a shorter delay.
  - **Looping:** the song leaving repeats its last 1, 2, 4, 8 or 16 beats while it goes.
  - **Beatmatching** on or off (not available when the tempos are more than 30 percent apart).
  - The play button renders the mix as it will sound and plays it from a few seconds before the next song comes in, with a green line following it.
  - The transitions play whenever you play the playlist (in order or shuffled, where two songs with a designed transition meet); between the others, AutoMix decides. The queue shows the playlist's mix coming up.
- Mixes are rendered with the same engine as AutoMix, now with a five-band EQ, reverb, echo, a noise generator and beat loops for each song, and each song through its own mixer.

### For development
- `Tools/AutoMixCheck` checks every option of every part and every preset (in range, the first song alone at the start and the next alone at the end, no change faster than a 50 ms ramp), the timing the designer gives (presets keep the automatic timing, four bars eight bars earlier stay on the beat, beatmatching off, loops and echoes) and Camelot codes. `Tools/AutoMixRenderCheck` renders three designed mixes with reverb, loops, echo and noise (they start where the song is and join the next one within a millisecond) and checks that a muted song isn't heard.
- New screenshots: the Mix editor and its options sheet, on two songs the app makes for the occasion (`-OndaScene mix`).

## 1.13.0 (2026-10-27)

### Improved
- **AutoMix is now a real mix, prepared ahead like a DJ's.** Until 1.12.1 the iPhone's player changed the two songs' speed and volume while they played, which was imprecise, and songs far apart in tempo got a two-second cut. Now Onda builds the whole mix in advance, while the song plays, with a proper audio engine, offline and faster than real time:
  - Both songs go through their own time stretch (the pitch doesn't change), bass cut and high-pass filter, with volumes and filters automated every 12 milliseconds, and a peak limiter so two songs at once never distort.
  - **Tempos up to 30 % apart are matched** (half and double time count): the playing song glides to a tempo between the two over four bars, the next one comes in on the first beat of a bar at that tempo, and the two stay on the same beat (within a few milliseconds) while they play together for up to 16 bars and the bass passes from one to the other; then the new song glides back to its own tempo.
  - Long intros of the next song are skipped, so its main part arrives as the previous song leaves.
  - Tempos further apart, and songs without a steady beat, get a long crossfade (6–12 seconds) on the song's ending, filtered when the song has a beat. **There is never a cut.**
  - At the right moment the player hands over to the prepared mix, started on the exact sample of the system clock where the song is, and the mix carries straight on into the rest of the next song (joined with a 30 ms crossfade), so there is no jump on either side. While the mix plays, the player shows "AutoMix" where the audio format usually is, like Apple Music's "Mixing".
  - Seeking back into the start of a song that came in through a mix plays it from its own file.
- The queue tells when the mix is being prepared ("Preparazione del mix…") and why it falls back to a plain crossfade if it can't be made.

### Fixed
- **A crash with AutoMix:** analysing a song whose sound starts at its very first sample could crash the app (the first beat of its grid fell before the start of the file).

### For development
- New `Tools/AutoMixRenderCheck` (run in CI on macOS) renders real mixes between songs made by the check and measures them: the mix starts within a millisecond of where the song is at the handover and ends within a millisecond of where the next song carries on, it never goes silent, and the two songs' kicks land together through the overlap (median 2 ms, 90 % within 10 ms), also when the tempos meet from 24 % apart (124 → 126 and 124 → 100 BPM). `Tools/AutoMixCheck` checks the mix schedule (on the same beat all through the overlap, back to the next song's own tempo at the end) and a song with sound from its first sample.

## 1.12.1 (2026-10-27)

### Improved
- **AutoMix now mixes every pair of songs, as Apple Music's does.** In 1.12.0 it matched beats only for songs within 6 % of each other's tempo and only over the last eight bars, so with most songs it ended up as a crossfade on the last seconds, with the next song from its start. Now:
  - **Beats matched up to 20 % apart** (half and double time count): both songs change tempo to meet halfway, without changing pitch. The playing song glides to the meeting tempo during the bars before the mix, the next one starts at it, then glides back to its own.
  - **Longer mixes, earlier:** sixteen bars when both songs have a beat there and their tempos and keys are close (about 30–40 seconds before the end), eight or four otherwise. The mix starts on a downbeat, at a change of section when there is one nearby.
  - **Long intros are skipped:** the next song starts so that its main part (where it gets louder after the intro) arrives just as the previous song leaves, as a DJ would.
  - **Filters:** the outgoing song thins out through a rising high-pass filter at the end of the mix, on top of the bass swap.
  - **Tempos too far apart:** a cut on the beat; the outgoing song thins out (filter and bass cut) while the next one comes in on one of its downbeats, straight into its main part.
  - **Songs without a steady beat** (ballads, live recordings): a crossfade on the ending, filtered when the outgoing song has a beat; during the fade-out when it has one.
  - Songs of the same album are mixed too.
- **The queue shows what AutoMix will do** at the end of the current song, under its switch: for example "Mix a tempo: 16 battute, 124 → 126 BPM, 34 s prima della fine · il prossimo parte da 0:16", or why it falls back to a plain crossfade.

### For development
- `Tools/AutoMixCheck` now also checks that both tempos meet halfway with the beats landing within 2 ms (124 → 126 and 124 → 140 BPM), the cut on the beat for 124 → 100 BPM, the skipped intro (the next song's main part arriving as the previous one leaves), filtered crossfades and the outgoing song's high-pass. `Tools/EqualizerCheck` checks the new high-pass filter.

## 1.12.0 (2026-10-27)

### Added
- **AutoMix, like Apple Music.** Songs now flow into each other like a DJ set. Onda analyses each song on the iPhone (tempo, beat grid, bars, key, where the sound starts and ends, how it fades out) and picks the transition that suits the two songs:
  - **Matched beats:** when both songs are made to a steady beat at tempos within 6 % (half and double time count), the next song comes in on the first beat of a bar, sped up or slowed down to this song's tempo without changing its pitch. They play together for eight bars (four at slow tempos or with clashing keys): the next song without its bass at first, then the bass passes from one to the other on a beat and the first song fades out. Afterwards the new song glides back to its own tempo over eight seconds. The next song is started at an exact moment of the system clock, so the beats land together.
  - **Otherwise a crossfade fitted to the songs:** the silence at the end and at the start is left out; a song that fades out gets the next one during its fade; two beats that don't match get a short blend that passes the bass over halfway; a song that ends abruptly is followed right away; a quiet intro comes in under the end of the previous song.
  - Songs of the same album, one after the other in order, play as they are.
  - AutoMix works from the copy of the next song that Onda downloads ahead anyway, and the song then plays from that copy: no extra data. Each song is analysed once (about a second) and the analysis is kept.
  - Until a transition is planned, or when it can't be (karaoke on, a seek past it, a song over 15 minutes), the song ends with a short crossfade.
- **Settings → Playback → Song transitions:** AutoMix (the default), Crossfade (1–12 seconds, the old setting) or None. A crossfade set to 0 before this version becomes None. AutoMix can also be switched on and off at the top of the queue, as in Apple Music.

### For development
- `Tools/AutoMixCheck` (run in CI) checks the analysis and the planner on songs made by the check itself, whose beats, bars, key and silences are known: tempo, the grid within a few milliseconds of the kicks, downbeats, key (C major and A minor), silence at both ends, a song without a beat, and that matched beats land on each other within 2 ms, that tempos too far apart, fades and songs without a beat get crossfades, that albums play as they are and that volumes and bass cuts move the right way.
- The beat grid was tuned on real songs: for Daft Punk, Avicii, David Guetta, The Weeknd and Ed Sheeran, 77–99 % of the strong onsets fall within 15 ms of the grid, and the tempos come out exact (121.29, 122.88, 126.00, 126.00, 96/192 BPM); Queen's "Bohemian Rhapsody" and Adele's "Someone Like You", played freely, are recognised as not matchable.

## 1.11.0 (2026-10-27)

### Added
- **Recommendations that change every day.** The daily mixes, "Scelti per te" and the moods used to stay the same: the mixes were always the four most played artists, "Scelti per te" was the radio of the last song played, and each mood was always the same search. Now:
  - Onda learns your taste on the iPhone: what you play to the end, what you skip with "next" in the first 30 seconds, what you like, keep in playlists or download. Recent listening counts most, and the log stays on the iPhone (the last 3000 plays; clearing the history clears it too).
  - **Daily mixes:** six a day, drawn from your 16 favourite artists, the most loved more often and those featured the day before less often, so they rotate. Each mix starts from three of the artist's songs (different every day), mixes their radios together with your favourites by that artist, and leaves out songs you skipped twice lately or heard in the last day.
  - **Scelti per te:** from four songs you like, drawn every day, mostly songs you haven't played in the last week, plus a few favourites you haven't heard for two weeks. They stay the same all day; pull the Home down for new ones.
  - **Moods:** each has five searches, a different one every day, with the radios of the top results, so they last longer and change.
- **The player opens and closes like Spotify's.** It grows out of the mini player as a card that fills the screen, with the app visible behind it, and shrinks back into the mini player when closed. Dragging it down, the card follows the finger and gets smaller as it nears the mini player.
- **Pause when headphones come off.** Taking both AirPods out of your ears (or putting them in their case), switching off Bluetooth headphones or unplugging wired ones pauses the music instead of moving it to the speaker, and it carries on when they come back within half an hour. Taking out a single AirPod, or Beats with ear detection, pauses and resumes through the headphones' own commands.

### For development
- CI checks the recommendations without the network: the taste profile, that mixes stay the same all day and change from day to day, that favourites come up more often without taking every mix, and how mixes and picks are put together. A new screenshot shows the player card half way.

## 1.10.1 (2026-10-27)

### Fixed
- **No more gaps at the start of songs.** Since songs began loading quickly, the sound broke two or three times in their first seconds: Onda moved the playing song from the stream to its local copy as soon as the copy arrived, then to decoded Opus at Massima, and put the Volume uniforme / equalizer mix on after the song had started.
  - A song now keeps the stream it started with to the end. The local copy and Opus are still prepared meanwhile: they play from the next listen, or from the moment you move the progress bar, when a pause is expected anyway.
  - At Massima a song starts in the best format the iPhone plays directly: Dolby or AAC 256 kbps when YouTube has them, otherwise AAC; Opus plays from the next listen.
  - The Volume uniforme and equalizer mix is put on before the first note (it is nearly always ready at once, since the loudness comes with the audio links; after 0.6 s the song starts anyway).

## 1.10.0 (2026-10-26)

### Improved
- **Songs start much sooner.** Onda now asks YouTube for a song's audio links the way YouTube's visionOS app does: one request of about a third of a second, answered with direct links to every quality. Before, YouTubeKit downloaded the video's web page (over 1 MB) for every song, often YouTube's player script too (about 3 MB), and decoded the links, which took 1.5–3 seconds; it is still used whenever the quick way fails.
  - The quick way needs a visitor ID from YouTube, which is the same for every song: Onda keeps it between launches.
  - The same answer tells how loud the song is, so Volume uniforme no longer makes a request of its own.
- **One lookup per song.** All the qualities of a song come from a single lookup, instead of one for the quality that starts playing and another for the local copy or Opus.
- **Nothing competes with the first note.** The local copy, Opus, the next song and karaoke now start only once the song is audible, instead of downloading alongside its first seconds.
- **A song ready in advance.** On Wi-Fi, when the iPhone is cool and not in Low Power Mode, Onda keeps one paused player ready for the most likely next song (the next one in the queue, or the song you are looking at), with its first seconds already loaded, so it starts almost at once. It is dropped after two minutes, or as soon as it is no longer the likely one.
- Songs on screen are prepared only while they are actually visible, most likely first, and a row that scrolls away withdraws its request.

### Added
- **Start times** in Settings → Diagnostica: how long songs you pick take from the tap to the first note (median of the last 20), how long automatic changes take, and where the last one came from (already prepared, link ready, from the internet, file on the iPhone). The times stay on the iPhone.

### For development
- CI checks how direct links are read from YouTube's answer (no dubbed tracks, no compressed copies, no ciphered links), the start-time statistics, and, against the live service when YouTube answers CI, the quick way itself.
- Most of the prepared player, the start-time measurements and their check were written by ChatGPT, which ran out of usage before connecting them to the player.

## 1.9.2 (2026-10-26)

### Fixed
- Cancelling a running download now also cancels its detached Opus conversion worker between chunks, instead of continuing to use CPU until the whole song is converted. Cleanup finishes before the download removes its temporary files.
- Regression checks cover cancellation during conversion, cancellation before the worker starts and normal completion.

## 1.9.1 (2026-10-26)

### Improved
- **Less work during normal listening.** Wi-Fi now defaults to native AAC 128 kbps, like cellular. Existing explicit quality choices are kept; Maximum remains available.
- Only the next song's native AAC copy is prepared ahead. Upcoming songs are no longer converted from Opus to Apple Lossless, and old preparation is cancelled when songs change or playback pauses.
- Shared audio preparation stops once no caller needs it, while one cancelled caller cannot interrupt another caller's audio. Cache files become visible only when complete.
- Opus conversions for playback and downloads run one at a time at utility priority, and stop between chunks when iOS reports serious thermal pressure or Low Power Mode is enabled. Downloads fall back to native AAC.
- Karaoke AI prepares the current song on demand, stops on pause/background or excessive heat, and releases its model when it is no longer needed. Already prepared audio continues to play.
- Cover motion uses fewer sensor updates and stops from the first elevated thermal state, in addition to the existing background, Reduce Motion and Low Power Mode limits.

### For development
- CI runs regression checks for energy budgets and shared audio cancellation in addition to all existing app logic, karaoke, localization and screenshot checks.
- Temperature and battery improvements still need measurement on an iPhone; the automated checks verify scheduling and correctness, not physical device temperature.

## 1.9.0 (2026-10-26)

### Added
- **Song details.** Swipe up on the player, or choose **Informazioni sul brano** in any song's ··· menu, to see the song's general data on a card that opens at half height:
  - Artist and album (tap them to open their pages), release date, length and plays on YouTube.
  - The label that delivered the song and its ℗ line, and the credits (composers, lyricists, producers, engineers, performers…), as the label sent them to YouTube Music.
  - The audio: the format playing now, the downloaded copy's format and size, and the song's loudness compared with YouTube's reference, with what Volume uniforme does to it.
  - Videos that aren't catalogue songs show their description instead. Buttons open the song in YouTube Music or share it.
- **Equalizer** (Settings → Audio → Equalizzatore, or the player's ··· menu), with Spotify's presets: Acoustic, Bass Booster, Bass Reducer, Classical, Dance, Deep, Electronic, Hip-Hop, Jazz, Latin, Loudness, Lounge, Piano, Pop, R&B, Rock, Small Speakers, Spoken Word, Treble Booster, Treble Reducer, Vocal Booster and Flat.
  - Six bands (60 Hz to 15 kHz) drawn as a curve: drag a point up or down to make your own.
  - It works on every song, streamed or downloaded, karaoke included, and changes are heard at once.
  - When a preset raises some frequencies, the overall volume goes down by as much, so the sound doesn't distort.

### Improved
- **Lighter lists.** Song rows, the Home and the album, artist, playlist, search and download pages no longer redraw for every change of the player (loading, karaoke progress, lyrics, colours): only when the song that plays, or play and pause, change.

### For development
- CI checks the equalizer's filters (gains, stability, no clipping for any preset) and how song details are read from YouTube's descriptions (offline, and against the live service when YouTube answers CI). Screenshots include the song details, in Italian and English, and the equalizer.

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
