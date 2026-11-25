# beatpad

Feel the beat — and optionally the melody — of any audio through your Force Touch
trackpad. Play a local file, follow system audio or an app, or listen through a
microphone, line-in, or USB interface. Rest your fingertips lightly on the pad.

## Requirements

- Force Touch trackpad: MacBook 2015+ or Magic Trackpad 2+.
- macOS 13+ for local files and metronome; macOS 14.2+ for live and listen modes.
- Xcode Command Line Tools (`xcode-select --install`).

## Build

```sh
./build.sh
```

This runs a release Swift package build, copies the executable to `./beatpad`, and
ad-hoc signs it. The capture permission descriptions are embedded in the binary.
Build products stay ignored. A plain `swift build -c release` also works; its
executable is `.build/release/beatpad`.

## Quick start

```sh
./beatpad --live
./beatpad --live --app Spotify
./beatpad --list-apps
./beatpad --input-list
./beatpad --live --input
./beatpad --live --input "USB"
./beatpad /path/to/song.wav
./beatpad --metronome --offset-ms 0
```

Live and listen modes default to all system audio. `--listen` displays audio levels
without touching the motor. `--app` matches running app names, case-insensitively
(exact, then prefix, then contains), or bundle IDs (exact or a dotted prefix), and
includes their audio helper processes. Start playback before selecting an app.
`--list-apps` shows one line per app currently playing audio, grouping helpers.
`--list-apps --all` lists every audio process with bundle ID, PID, and output activity. Chrome plays from helper processes, which are matched automatically.
Safari plays from WebKit processes: use `--list-apps` to find them, or system audio.

`--input` selects the default input. Supply a name substring (case-insensitive) or
an exact device UID to select another device. Input is mixed to mono for analysis.
Its speaker timing correction is zero because the sound is already in the room;
use `--offset-ms` to adjust. With microphone input and `--melody`, the microphone
can hear the trackpad's own tones.

Use the metronome to tune timing. If the thump comes before the click, raise
`--offset-ms`; positive values make haptics later. Ctrl-C stops playback.

## When the trackpad moves

The built-in trackpad runs only while sound goes to the built-in speakers and the
lid is confirmed open. Other outputs pause haptics while analysis keeps running;
switching back resumes automatically. `--any-output` allows headphones and other
outputs, but the built-in pad still requires a confirmed open lid. An unreadable
output route (device, transport or data source) or lid state counts as “not allowed”.
Unreadable volume or mute means volume is not followed. Haptics pause within about
a quarter of a second of switching output (immediately on most switches via change notifications)
and within about a second of closing the lid. A burst already in progress finishes,
taking at most about 40 ms. A stalled output check also pauses built-in haptics.

`--external` selects a Magic Trackpad, which is exempt from the output and lid
restrictions. Desktop Macs using a Magic Trackpad are also exempt, even without
`--external`; the exemption follows the trackpad actually opened.

## Options

| Flag | Meaning |
| --- | --- |
| `--help`, `-h` | Show usage. |
| `--live` | Predict live beats and drive the trackpad. |
| `--listen` | Meter live audio without haptics. |
| `--app NAME_OR_BUNDLE_ID` | Capture a running app and its helpers. |
| `--system` | Explicitly capture all system audio (the default). |
| `--input [DEVICE]` | Default input, device name substring, or exact UID. |
| `--list-apps [--all]` | List playing apps; `--all` includes every audio process. |
| `--input-list` | List input names, UIDs, and channels. |
| `--seconds N` | Stop live/listen after N seconds, greater than zero. |
| `--metronome` | Play 16 clicks with thumps. |
| `--melody` | Add live melody tones; also works in simulation. |
| `--melody-only` | Melody without beat thumps; implies `--melody`. |
| `--melody-level X` | Relative melody strength, 0…1; default 0.5. |
| `--melody-octave N` | Shift melody by −2…+2 octaves; default 0. |
| `--dry-run` | Print file/metronome hits and totals; no audio or motor. |
| `--offset-ms N` | Shift haptics against audio; positive = later; default 0. |
| `--level X` | Master strength, 0…1; default 1.0. |
| `--no-dynamics` | Disable quiet/loud section scaling (metronome always excludes it). |
| `--dynamics-range DB` | Quiet-to-loud range, greater than zero; default 15 dB. |
| `--no-follow-volume` | Disable following Mac output volume and mute. |
| `--sensitivity X` | Higher = more hits, 0…1; default 0.5. |
| `--mode beat\|onsets` | File analysis: tracked beats (default) or individual onsets. |
| `--kick-only` | Drop beat ticks and onset accents. |
| `--start SEC` | Start partway through a file; default 0. |
| `--bpm N` | Force file/live tempo or metronome tempo, greater than zero; metronome default 120. |
| `--any-output` | Allow any audio output; the built-in trackpad still requires an open lid. |
| `--external` | Use an external Magic Trackpad. |
| `--` | End option parsing, useful for filenames starting with a dash. |

Choose one main mode or one audio file. Source options are for live/listen and are
mutually exclusive. Melody options require live or simulation. File-only options
are rejected in live/listen where they do not apply. Apple Music/DRM-protected
files cannot be read.

## How it works

Capture → spectral onset analysis → tempo and phase prediction → motor. Prediction
schedules thumps ahead of time so they land on the beat, compensating for output
latency in system/app capture. Local files use an offline beat grid. Low-band
energy shapes thumps; other onsets become lighter ticks. Dynamics scale strength
with quiet and loud passages. Output volume and mute scale it again unless
`--no-follow-volume` is set. Optional causal melody analysis estimates sustained
pitches and turns them into brief motor tones between beats.

## Privacy

Nothing is recorded, saved, or sent during playback or capture. There is no network
access at all. Analysis uses temporary in-memory audio buffers. System/app capture
needs macOS **Screen & System Audio Recording** permission for your terminal app;
it captures audio, not the screen. Microphone/input capture needs **Microphone**
permission for your terminal app. Permission descriptions are embedded in the
executable. The explicit development commands below can write synthetic WAVs and
benchmark splice WAVs locally.

## Safety and caveats

The private MultitouchSupport API may break with macOS updates. beatpad caps
requested amplitude at 1.0 from the private actuation API, the same ceiling
nospeaker uses. Every actuation is a short burst: one cycle for thumps and at most
about 40 ms per melody chunk. Melody drives the motor nearly continuously while
a melody is present — far more than the brief taps it is designed for. Take breaks
and don't leave melody running unattended. Hardware safety across models is not
guaranteed. Use at your own risk; keep speaker volume moderate and stop if the
sensation is uncomfortable.

## Known limitations

- Built-in headphones count as “not the speakers”; use `--any-output` to allow them.

- A tempo change to roughly half or double the previous tempo (for example,
  152 → 74 bpm) can stay at the old metrical level until a pause, with thumps at
  double time and every other thump on the beat.
- Dense mixes can confuse beat and melody tracking. Melody is an approximation
  with a limited motor frequency range.
- Melody trails audio by about 40 ms because it cannot be predicted.
- Bluetooth outputs add latency; tune with `--metronome` and `--offset-ms`.
- Safari audio comes from WebKit processes; select them or use system audio.

## Troubleshooting

- Silence: start audio, check `--list-apps` or `--input-list`, and check permissions
  in System Settings → Privacy & Security. For system audio, enable your terminal
  under Screen & System Audio Recording → System Audio Recording Only; quit and
  reopen it. For input, enable the terminal under Microphone. Three seconds of
  all-zero input triggers a microphone permission hint.
- Bluetooth latency: tune `--offset-ms` with the metronome for your listening setup.
- Safari: select the playing WebKit process shown by `--list-apps`, or use system
  audio capture.
- Missing trackpad: check for a Force Touch model, or try `--external` with a Magic
  Trackpad 2+.

## Development

```sh
./beatpad --selftest
./beatpad --simulate-live /path/to/song.wav
./beatpad --simulate-live /path/to/song.wav --melody
./beatpad --write-test-track /tmp/test-track.wav
python3 bench/bench.py --tracks /path/to/tracks.json tune
python3 bench/bench.py --tracks /path/to/tracks.json splice
```

| Development flag | Meaning |
| --- | --- |
| `--selftest` | Deterministic detector, tracker, dynamics, volume, melody, and scheduler checks; no audio or motor. |
| `--simulate-live FILE` | Measure causal tracking against the offline grid. |
| `--splice-at SEC` | Separate segment references and measure transition recovery; simulation only. |
| `--jitter-us N` | Timestamp jitter ±N microseconds; default 200, minimum 0; simulation only. |
| `--write-test-track PATH` | Write a synthetic 12-second WAV. |

Copy the schema from `bench/tracks.example.json` into your own manifest outside the
repository. `tune` and `holdout` contain arrays of audio paths; `all` measures both.
Relative paths resolve against the manifest directory. `splice` contains cases
with `name`, `first`, `first_start`, optional `first_length`, `second`, and
`second_start`. `splice_length` defaults to 60 seconds and supplies the default
first segment length and second segment duration. Splices are hard cuts at 48 kHz.
The harness requires Python 3 and `ffmpeg` for MP3 conversion and splices. Generated
audio stays in ignored `bench/.cache/`; no benchmark logs are written. Set
`BEATPAD_BIN` to compare another executable. Keep personal manifests and audio out
of this repository.

The Swift package separates capture, analysis, tracking, scheduling, motor access,
and command-line dispatch under `Sources/beatpad/`. CI builds and runs self-tests
on macOS 15.

## Credits and license

Motor access is adapted from [nospeaker](https://github.com/os6/nospeaker) by Cody
Collier. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for its MIT notice.

beatpad is MIT licensed, copyright © 2026 UFD Media. See [LICENSE](LICENSE).
