# AutoMix: Segue transitions

AutoMix, and the playlists' Mix that builds on it, are **beta features**: they are marked *Beta* in
the apps, on the account page and in the README, while their tuning is confirmed by listening on
more devices and genres.

On iPhone, iPad and Mac, AutoMix plans a transition with its Segue engine and plays it ahead into a
file (`SegueRender`), both songs' tempos gliding, never in a step; playing it live on two players in
step (`SegueSession`) is the fallback when that can't be done. The engine is in `Seaglass/Player/Segue/`. It is Seaglass's own code,
written after the behaviour of the "Segue" engine of Myspoti (kota-zo/myspoti, GPL-3.0). None of
Myspoti's code is used or translated, so Seaglass keeps its own licence. This page describes what
the engine does, where it differs from Segue and what still needs listening on real devices.

The rendered mix (`AutoMixRenderer`, chosen by `TransitionPlanner`) is still there. It runs when
the live mix is turned off (Settings → Riproduzione → Mix dal vivo), when a playlist has its own
Mix design, when an album plays in order, for podcasts, with Dolby Atmos and other multichannel
items (their audio can't be processed), and whenever a live transition can't start in time.

## The plan

A transition is data (`SeguePlan`): where the window starts in each song's own time, the incoming
song's speed during it, the window's length, and the lanes. A lane is one quantity of one song
over the window (its level, a band of a three-band equalizer, a low-pass or high-pass cutoff), as
knots joined by curves (step, linear, exponential for frequencies, power). The players decide
nothing: they play the lanes.

`SeguePolicy` writes the plan from the two songs' analyses (`TrackAnalysis`) and their measured
voices (`VocalActivity`, from the karaoke's vocal model, near the end of one song and the start of
the next). The same two songs always give the same plan.

## Beats and bars

The bars come from Beat This! (Foscarin, Schlüter and Widmer, JKU Linz, ISMIR 2024; MIT licence,
code and weights), the neural beat tracker Myspoti's Segue also plans on. Its `small0` checkpoint
is converted to Core ML in CI and bundled; `Seaglass/Player/BeatThis.swift` computes its log-mel
input as upstream does and runs it in chunks of 30 seconds. When AutoMix analyses a song, the
model's beats and downbeats are added to the analysis (not in Low Power Mode or when the device is
hot: then the song is planned on Seaglass's own grid, as before, and the model runs the next time).

Where the next song comes in: its first attack, or a section or phrase start up to a minute in
(never past a third of its music), or where it arrives after the window. A section start ranks
near the attack (above it when the first eight bars are a quiet intro, 3 dB or more under the
song), and up to 30 seconds of the song's start may be left out without counting as music lost; a
quiet intro the window spans, the song arriving right after it, ranks as the attack does.

With the model, a song's bars are its beats, every fourth starting a bar on the beat its downbeats
vote for near the song's start and near its end. Each bar keeps how sure the model was of its
downbeat. Sections come from the analysis' harmony and loudness changes, phrases are 8 bars from
the last section start. A stretch is fitted on the model's beats inside it: at least 85 % of the
beats it should hold, 95 % of them within 40 ms of a straight line, no bar sliding more than 30 ms
off it, and downbeats the model was at least 50 % sure of on average. A build-up without clear
beats, which the next song arrives after, takes the beat of the bars it leads into.

## Levels

The policy tries these levels in order and keeps the first whose best candidate passes:

| Level | What it is |
| --- | --- |
| `lockedLong` | Beat-matched over 16 bars, on a phrase in both songs. |
| `lockedShort` | Beat-matched over 8 or 4 bars, on a phrase in both songs. |
| `lockedBeat` | Beat-matched over 4 or 2 bars, on any bar. |
| `filtered` | A fade of 8, 6 or 4 seconds with filters and the bass handed over, at the songs' own speeds. |
| `hard` | A cut on a downbeat, with a short ramp against clicks. |
| `simpleFade` | A plain 6-second fade (2.5 seconds at the very end when voices would meet). |
| `normal` | No transition: one song after the other. |

Beat-matched levels also try the incoming song at half or double the number of bars (half or
double tempo) for 8 bars or fewer. A level that is refused leaves a reason (`SegueAttempt`: no
grid, tempo out of reach, length not allowed by the grid's reliability, guards crossed with
counts, score below the threshold, invalid plan). Settings → Informazioni shows the last choice
and the reasons.

## Length, equaliser and echo

Settings › Riproduzione, under Mix dal vivo:

- **Durata del mix.** Breve allows beat-matched windows of up to 8 bars (filtered fades of 6 or
  4 seconds, a 4-second plain fade); Normale up to 16 (8, 6 or 4 seconds; 6); Lunga up to 32 bars,
  tried first when both songs' stretches are reliable enough, with filtered fades of 14, 10 or 8
  seconds, a 10-second plain fade, and the outgoing song free to leave from the last 45 % of its
  music instead of the last third. The longest length that clears its threshold plays.
- **Equalizzazione automatica.** On, the lanes hand over the bass, the bands, the filters and the
  echo. Off, only the levels move, and the level that beat-matches on any bar (it relies on the
  bass swap) is left out.
- **Echo.** Some locked windows (`echoTail`) shut the outgoing song's fader a beat before the end
  while a send throws its last beats into an echo; some filtered fades (`echoOut`) throw it in
  late. The delay is on the song's beat (a dotted eighth, a beat, an eighth or a beat and a half,
  between 240 and 620 ms), each repeat at half the level, the send's bass cut under 250 Hz. The
  faders make room for the send in the 1.1 sum bound. The outgoing player runs 3 seconds past the
  window for the repeats to ring out, so the shapes are chosen only where the song has them.

## Guards and score

Guards reject a candidate whatever its score:

- the two songs' tempos are more than 8 % apart (the speed change the mix needs);
- the expected beat misalignment exceeds 20 ms (median) or 40 ms (95th percentile);
- the grids drift apart by more than 0.1 beat over the window;
- two voices are heard together, both within 10 dB of full level, for more than 1 second
  (measured voices only; cuts are exempt);
- more than 60 seconds, or a fifth, of the outgoing song is left out;
- the outgoing song plays less than a minute;
- a cut jumps by more than 3 dB.

The beat misalignment comes from stretches: the bars of the window in each song are fitted with a
straight line through their clearly marked beats (at least 85 % marked, no bar more than 30 ms off
the line). A song whose whole grid is not steady can still have a steady stretch, and a mix needs
no more.

The candidates that pass are scored: the sum of each note (rhythm, phrase, energy continuity,
instrumental exit, entry point, key) times its weight and how reliable its measure is, minus each
defect (speed change, voices together, voices cut off, bass clashing, music left out, number of
effects) times its penalty. The best candidate of a family must reach its threshold: 0.5 for
beat-matched levels, 0.25 for filtered fades and cuts. All the numbers are in `SegueTuning`.
They are starting values from DJ practice and need listening to confirm them.

## Shapes

The policy chooses the shape, the compiler (`SegueCompiler`) writes it as lanes:

- `bassSwap`: the incoming song comes in under the outgoing one without its bass, the bass changes
  hands on one downbeat over a beat (low shelf at −30 dB), then the outgoing song leaves; its top
  end goes down over the last part.
- `threeBand`: the bass, then the middle, then the top change hands.
- `filterOpen`: as `bassSwap`, the incoming song opening from a low-pass.
- `riseOut`: as `bassSwap`, the outgoing song leaving through a rising high-pass.
- `cutOnBeat`: one song, then the other, on a downbeat (when voices would meet).
- `sweepOut`, `evenFade`, `quickOut`, `lateOut`: the filtered fades.
- `cut`, `fade`: the cut and the plain fade.

Levels are written from gains: equal power, with the two faders' sum kept at 1.1 or less, so two
peaks meeting on a beat stay in range. A louder incoming song is brought to the outgoing one's
level (up to 6 dB) and back to its own after the bass changes hands.

## Playing it

Each player's audio processing (`EqualizerTap`, after the equalizer's effects) has a deck,
`SegueStage`. A deck reads its lanes by the time of the very samples it processes, so what is
heard follows the music whatever the output's latency. It works on blocks of 64 frames with the
level interpolated in between, uses state-variable filters (Simper's trapezoidal SVF, stable while
they move), and on the audio thread it doesn't allocate, wait, log or read files: a new plan comes
in under a lock the audio thread only tries.

## Played ahead

`SegueRender` plays the plan into a file as soon as it is written (a minute or more before the
window), from both songs' own files decoded to memory, and the player plays that file followed by
the next song's own file in one item (`AutoMixPlayback`). AVPlayer can't change a playing song's
speed without its sound being rendered again (see below), so every change of speed happens in the
file instead, sample by sample:

1. The file starts a second before the window with the playing song alone, its own samples at its
   own gain, exactly as its player plays them. Its player comes in a third of a second later, silent
   until then (so its start is never heard), at an exact moment of the system clock computed from
   the playing song's timebase, and the two cross over in 80 ms on the same music, in phase: the
   playing song gives way on its own samples (its deck's lanes), the file comes in on its volume
   ramp. Nothing changes speed there.
2. Through the window the next song is locked to the playing one: its place follows from the
   playing song's as the plan has it, so its beats stay on the other's whatever the speeds do. The
   tempo goes from the playing song's to the next one's over the window (eased at both ends, no
   corner in the speed): the playing song from its own speed to 1/rate, the next one with it from
   `rate` to its own. The song heard most is always at or near its own tempo, and by the window's
   end (the mark on the progress bar) the next song is at its own speed: nothing changes after it.
   The lanes play on each song's own time through the same deck as live (`SegueStage`), the echo's
   delay kept on the beat.
3. After the window the next song's lanes go back to plain, then it goes onto its own samples (the
   last fraction of a frame made up over a second, a few hundred-thousandths of speed). The file ends
   with a second and a half of its own samples, exactly, and the item carries on with the song's own
   file from there (`join`, a whole frame), crossfaded over 30 ms on the same music; the song's part
   plays silent for half a second before, so its decoder and its processing are running when it
   comes in, and both parts go through the same processing.
4. A speed is a resampling with a 64-tap windowed sinc (Kaiser), flat to about 20 kHz and exact on a
   whole frame, so the song sounds as its own through and after the mix (a cubic filter dulled the
   top octave by a few decibels while it resampled, heard as the song's own sound coming back when
   the resampling stopped). The pitch moves with the tempo, as on a turntable, with no time stretch
   and its artefacts. A soft limiter (a knee at 0.95) works only where both songs play.

The render reports the largest difference between the file and the songs at both ends (0), the
largest change of a song's speed from one frame to the next, and the decks' jumps; a render that
isn't exact at both ends isn't played. A song brought in this way is handed on from its own file
(after the join), where the next file can take over on its very samples.

## Played live (the fallback)

When a transition can't be played ahead (a file can't be read, the playing song isn't at its own
speed), `SegueSession` runs it live:

1. 15 seconds before the window, the next song is loaded on a second player, its deck armed and
   prerolled. It keeps the app's way of changing speed (Tempo's key lock: Apple's spectral
   algorithm, or resampling); never the time-domain one, which is made for speech and stutters on
   music.
2. For a beat-matched window the **next song** is the one stretched: it starts, silent, at the
   playing song's tempo, is kept on the beat only while it is still quiet in the mix, and after
   the window comes back to its own speed on a fresh player (equal-gain crossover on a downbeat
   about two seconds on). The playing song is never carried to the next one's tempo on other
   players: each step of that glide was heard as a short skip, and the change began before the
   mix. Leaving the next song at the mix's speed for the rest of the track kept the wrong tempo
   until pause or stop; the brief return after the window is the compromise. A pause or a seek
   also brings it back (they hide a change of speed).
3. The next song starts a third of a second before the window, silent until it, at an exact
   moment of the system clock computed from the playing song's timebase (so whatever a player does
   as it starts is never heard). For a window that doesn't match beats it starts 2.5 seconds
   before the window at the plan's speed and, after the window, goes back the same way when its
   rate isn't already 1.
4. Every 50 ms the next song's distance from its place is measured (the median of the last five
   readings: a player's time moves in steps of 10–20 ms) and made good by nudging its speed: fast
   while silent (up to 8 % over 0.3 s, a seek past 0.4 s), and while it is still quiet in the mix
   (under a third of its level) only once it drifts past 20 ms, up to 1.5 % over 0.8 s, until it
   is within 5 ms; once louder, never. On CI's Mac (songs made by the app, 126 BPM to 124 and
   128 to 126) it was on its place when the window opened and stayed there through 8- and 16-bar
   mixes with no correction at all, by the players' clocks. They all play to the same output, so
   what is heard keeps that alignment; it hasn't been measured on the sound itself.
5. When the window starts the next song's player becomes the main one (the queue moves on). The
   playing song's player is let go once the window (and its echo) is over. After the window the
   session brings the next song back to its own speed on a fresh player when needed, then ends.
6. Why no playing player's *rate* ever changes in place: a playing player renders its sound again
   whenever its rate changes, and its time jumps by 20–40 ms (CI's Mac: the deck's samples jumped,
   and the measured distance with them). Brought back in steps every 250 ms (with the time-domain
   algorithm), the song was heard on an iPhone coming and going; brought back in one rate change
   after the window, as a cut; giving the change to the playing song by changing its rate as the
   window opened put the two 100 ms apart; kept to the song's end, the song stayed slowed and
   stretched. The post-mix fresh-player crossover restores the natural tempo without changing a
   playing player's rate.
7. Until the window is over nothing else starts: the song's own preparation (its local copy, the
   next song's stream) and the analysis of the transition into the next song wait, so that the
   vocal model doesn't compete with the players for the processor. Then the session goes, and the
   next transition is planned as for any song.

If anything goes wrong before the window (the file isn't ready, the moment has passed, the queue
changed, the song was paused), the live transition is dropped and the song plays on; that pair
isn't tried live again. A seek before the window only starts it over: the plan stays, and the
next song is armed again as the playing one nears it. Once the window is over, the next song's
deck goes back to plain sound (its release counted by the sound played, not by the song's time),
so a seek back to before its window, where its lanes are silent, still plays it. If the incoming song stalls or drifts more than 0.4 s once
heard, the lanes ramp back to plain sound over 0.4 s and the songs carry on as they are.

## Differences from Segue

- Beat This! runs on Core ML at full precision (Segue runs an int8 copy through ONNX Runtime); the
  beats are its peaks, without Segue's onset grid on top.
- Voices are measured only near the end of the outgoing song and the start of the next, with the
  karaoke's MDX model, and only when the device allows it (energy, time). Unmeasured voices count
  as unknown: guards don't reject on them, the score trusts them less.
- An echo send, but no reverb ("room") send.
- The faders' sum is bounded; played ahead, a soft limiter works where both songs play (live, each
  plays on its own `AVPlayer` and iOS mixes them).
- Album songs played in order keep Seaglass's album junction, rendered exactly.
- Played ahead, speeds are changed by resampling, so the pitch moves with the tempo (the quieter
  song shifted, the louder one at or near its own); Segue keeps the key with a time-stretch engine
  and brings the next song back to its own speed after the mix, where here it is there by the
  window's end. Live (the fallback), speeds are `AVPlayer`'s, which can't glide.

## Checks

On CI's Mac, `bash Tools/SegueScene/run.sh` plays three songs made by the app (124, 126 and
128 BPM) through two mixes in a row, and checks that both are played ahead (the live session never
runs), that each file is the songs' own samples where it takes over and hands back, that no speed
changes in a step and no deck jumps, that the file's player takes over within 2 ms of the playing
song, and that each mix carries on into the next song's own file.

`bash Tools/SegueRenderCheck/run.sh` renders a plan the policy wrote for songs made there and checks
the file's both ends against the songs' samples (exactly), the next song's beats on the playing
song's through the window while the tempo glides from one song's to the other's (no drift, no step
from one beat to the next), the next song at its own tempo as soon as the window ends, a high tone
at its own level while resampled, and no click in a mix of two tones.

`bash Tools/SegueCheck/run.sh` builds songs whose beats, bars and voices are known and checks the
levels the policy reaches and why the others were refused, that plans are valid and the same for
the same songs, the faders' sum, silence before and after the window, the decks' sound on
samples (untouched unarmed, no step in the level, a release back to plain, filters stable while
they sweep), and a whole beat-matched mix rendered through two decks (in range, no hole).

## Still to confirm on devices

- The timing of the second player's start and the speed corrections on iPhone, iPad and Mac, with
  wired, Bluetooth and AirPlay outputs (AirPlay's latency is the same for both players, but the
  start is less precise).
- The tuning values by listening, on a variety of genres.
- Energy use with two players and the vocal model on battery.
