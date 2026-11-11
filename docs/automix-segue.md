# AutoMix: live transitions

On iPhone, iPad and Mac, AutoMix can play a transition live, on two players in step, instead of
rendering it into a file. The engine is in `Seaglass/Player/Segue/`. It is Seaglass's own code,
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

`SegueSession` runs the transition:

1. 15 seconds before the window, the next song is loaded on a second player, its deck armed and
   prerolled at the plan's speed. It keeps the app's way of changing speed (Tempo's key lock:
   Apple's spectral algorithm, or resampling); never the time-domain one, which is made for speech
   and stutters on music.
2. 2.5 seconds before the window it starts, silent, at an exact moment of the system clock
   computed from the playing song's timebase.
3. Every 50 ms its distance from its place is measured (the median of the last five readings: a
   player's time moves in steps of 10–20 ms) and made good by nudging its speed. While silent it
   is corrected fast: up to 8 % over 0.3 s, with a seek if it is more than 0.4 s off.
4. When the window opens (on its first downbeat), the speeds change hands, in step as they were:
   the playing song goes to the next one's tempo (its pitch kept beyond 1 %), the next song, still
   silent there, to its own speed, which it keeps. The second player becomes the main one (the
   queue moves on). The reason: a player renders its sound again whenever its rate changes, and
   that can be heard. On CI's Mac every change made the deck's samples jump; bringing the song
   back to its speed after the window, in steps every 250 ms with the time-domain algorithm, was
   heard on an iPhone as sound coming and going for 10–20 seconds. Now the song that stays is
   never changed while it is heard on its own, and the one that goes changes once.
5. Once heard, the next song is corrected only when it drifts, so its tempo never sways and its
   player seldom renders again: nothing until it is 20 ms off, then up to 0.8 % over 2 s (1.5 %
   over 0.8 s while it is still low in the mix) until it is within 5 ms. On CI's Mac (songs made by
   the app, 126 BPM to 124 and 128 to 126) it was on its place when the window opened and stayed
   there through 8- and 16-bar mixes, by the two players' clocks. Both play to the same output, so
   what is heard keeps that alignment; it hasn't been measured on the sound itself.
6. When the window ends, a correction still under way is taken back (one change), and the old
   player is released once its sound (and its echo) is out.
7. Until then nothing else starts: the song's own preparation (its local copy, the next song's
   stream) and the analysis of the transition into the next song wait, so that the vocal model
   doesn't compete with two players for the processor. Then the session goes, and the next
   transition is planned as for any song.

If anything goes wrong before the window (the file isn't ready, the moment has passed, the queue
changed, the song was paused or moved), the live transition is dropped and the song plays on;
that pair isn't tried live again. If the incoming song stalls or drifts more than 0.4 s once
heard, the lanes ramp back to plain sound over 0.4 s and the songs carry on as they are.

## Differences from Segue

- Beat This! runs on Core ML at full precision (Segue runs an int8 copy through ONNX Runtime); the
  beats are its peaks, without Segue's onset grid on top.
- Voices are measured only near the end of the outgoing song and the start of the next, with the
  karaoke's MDX model, and only when the device allows it (energy, time). Unmeasured voices count
  as unknown: guards don't reject on them, the score trusts them less.
- An echo send, but no reverb ("room") send.
- The faders' sum is bounded, but there is no limiter shared by the two players (each plays on its
  own `AVPlayer`; iOS mixes them).
- Album songs played in order keep Seaglass's album junction, rendered exactly.
- Speeds are changed by `AVPlayer` (resampling, or time stretching with the pitch kept), not by a
  dedicated time-stretch engine. A player's rate can't glide without its sound being rendered
  again, so the speeds change hands once, when the window opens, instead of the next song being
  brought back to its own speed little by little after it.

## Checks

On CI's Mac, `bash Tools/SegueScene/run.sh` plays three songs made by the app (124, 126 and
128 BPM) through two live mixes in a row, and checks that each song brought in plays at its own
speed after its window and that the second mix comes after the first. Its log counts the speed
changes while the next song is heard and the jumps in each deck's samples.

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
