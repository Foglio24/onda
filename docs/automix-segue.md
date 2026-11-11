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

## Guards and score

Guards reject a candidate whatever its score:

- the incoming song's speed changes by more than 8 %;
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
   prerolled at the plan's speed (within 1 % by resampling, more with the pitch kept).
2. 2.5 seconds before the window it starts, silent, at an exact moment of the system clock
   computed from the playing song's timebase.
3. Every 50 ms its distance from its place is measured (the median of the last five readings: a
   player's time moves in steps of 10–20 ms) and made good by nudging its speed. While silent it
   is corrected fast: up to 8 % over 0.3 s, with a seek if it is more than 0.4 s off. Once heard
   it is corrected gently, so its tempo never sways: nothing within 12 ms, then up to 0.8 % over
   2 s (1.5 % over 0.8 s while it is still low in the mix). On CI's Mac (two songs made by the
   app, 126 BPM slowed to 124) its time was on its place when the window opened and stayed there
   through a 16-bar mix, by the two players' clocks. Both play to the same output, so what is
   heard keeps that alignment; it hasn't been measured on the sound itself.
4. When the window starts, the second player becomes the main one (the queue moves on). When it
   ends, the old player is released and the new song goes back to its own speed a little at a
   time (0.1 % per beat, over at least 16 beats).

If anything goes wrong before the window (the file isn't ready, the moment has passed, the queue
changed, the song was paused or moved), the live transition is dropped and the song plays on;
that pair isn't tried live again. If the incoming song stalls or drifts more than 0.4 s once
heard, the lanes ramp back to plain sound over 0.4 s and the songs carry on as they are.

## Differences from Segue

- Beats come from Seaglass's own analysis (onset grid, downbeat, beat strengths, local timing),
  not from a neural beat tracker. The reliability of each stretch is measured on its own beats.
- Voices are measured only near the end of the outgoing song and the start of the next, with the
  karaoke's MDX model, and only when the device allows it (energy, time). Unmeasured voices count
  as unknown: guards don't reject on them, the score trusts them less.
- No echo, delay or reverb shapes: Seaglass has no send effects.
- The faders' sum is bounded, but there is no limiter shared by the two players (each plays on its
  own `AVPlayer`; iOS mixes them).
- Album songs played in order keep Seaglass's album junction, rendered exactly.
- The incoming song's speed is changed by `AVPlayer` (resampling within 1 %, time stretching
  beyond), not by a dedicated time-stretch engine.

## Checks

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
