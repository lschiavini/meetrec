<p align="center"><img src="Resources/icon/AppIcon.svg" width="96" alt="MeetRec icon"></p>

# MeetRec

A small floating panel for macOS that records a meeting (computer audio and your microphone) and turns it into text on your own machine. No bot joins the call, nothing leaves your Mac.

![Recording](docs/screenshots/recording.png)

![Transcribing](docs/screenshots/transcribing.png)

![Text ready](docs/screenshots/done.png)

## What it does

- The panel floats over every space, can be dragged anywhere, and is excluded from screenshots, recordings and screen shares, so the other people on the call never see it.
- **Record** creates a folder named after the start time (`2026-11-11-1436`, plus the meeting name if you typed one) and saves `system.mov` (what the computer played) and `mic.mov` (your voice), then mixes them into `audio.m4a`.
- **Transcribe** writes `transcript.txt` (everyone) and `transcript-mic.txt` (your microphone only) into the same folder, locally with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper).
- **Copy name** puts `meeting: <folder name>` on the clipboard, ready to paste to an AI agent that reads the transcript and files your notes.
- The list button shows every earlier meeting. Picking one copies its name, and loads it for transcription if it has no text yet. The same list deletes a recording (to the Trash), opens the recordings folder, and changes where new recordings go.
- The x stops and saves a running recording, then closes the app.

## Requirements

- macOS 15 or later on Apple Silicon (mlx-whisper runs on the Apple GPU)
- Xcode 16 or the Command Line Tools with Swift 6 (`xcode-select --install`)
- [`ffmpeg`](https://ffmpeg.org) and [`uv`](https://docs.astral.sh/uv/)

```sh
brew install ffmpeg uv
```

## Run it

```sh
git clone https://github.com/lschiavini/meetrec.git
cd meetrec

# 1. Config: where recordings go, which Whisper model, words to expect
mkdir -p ~/.config/meetrec
cp config.example.json ~/.config/meetrec/config.json

# 2. Build MeetRec.app, copy it to /Applications and launch it
./scripts/build-app.sh --install
```

Without `--install` the app is built to `build/MeetRec.app` and nothing is copied.

The first recording asks for two permissions: **Screen & System Audio Recording** (that is how macOS hands out computer audio; no video is kept) and **Microphone**. The first transcription downloads the Whisper model (over 1 GB for `whisper-large-v3-turbo`), so it takes longer than the ones after it.

If you have a code-signing identity in your keychain, the build script signs with it so the permissions survive rebuilds. Otherwise it signs ad hoc and macOS asks again after each rebuild. Set `MEETREC_SIGN_IDENTITY` to pick a specific identity.

## Config (`~/.config/meetrec/config.json`)

| Key | Meaning |
|---|---|
| `recordingsDir` | Where recording folders go (default in the example: `~/Downloads/audio-recordings`) |
| `whisperModel` | Any mlx-whisper model on Hugging Face, e.g. `mlx-community/whisper-large-v3-turbo` |
| `vocabulary` | Names, products and jargon the transcriber should expect, comma separated |
| `languages` | Optional, e.g. `it,pt`: the languages spoken. Empty means detect them per recording |

## Command line

Everything the panel does also works from the terminal. `./scripts/build-app.sh --install` links the `meetrec` command into `~/.local/bin` (add `--no-launch` to skip opening the panel).

```sh
meetrec record "Design review"       # records until Ctrl-C, then saves and mixes
meetrec record standup --for 15m     # stops by itself after 15 minutes
meetrec start "1:1 with Ana"         # background recording; prints the folder
meetrec status                       # recording or not (exit 1 when not)
meetrec stop                         # saves and mixes the background recording

meetrec list                         # newest first; * = has a transcript, ● = recording now
meetrec transcribe                   # latest meeting; or name one: meetrec transcribe design
meetrec transcribe ~/Downloads/call.m4a   # imports an audio file as a new meeting
meetrec show design                  # print the transcript (--mic: your microphone only)
meetrec copy design                  # "meeting: <name>" on the clipboard, for an agent
meetrec rename latest "Design review v2"
meetrec delete 2026-11-11-1530       # to the Trash; never assumes "latest"

meetrec folder ~/Meetings            # change where new recordings go
meetrec config languages it,pt       # set any config key
meetrec selftest 5                   # record 5 seconds to /tmp and show both tracks
meetrec help
```

A meeting can be named by its full folder name, any unique part of it, a folder path, `meeting: <name>` as copied, or `latest` (the default where it makes sense).

Recording runs inside MeetRec.app, launched without its panel, so it uses the app's recording permissions and your terminal needs none. A recording started from the terminal does not show in a panel that is already open. `MEETREC_CONFIG` points the command at a different config file, `MEETREC_APP` at a different build.

Other entry points:

```sh
# The processing script the app and the CLI both use
/Applications/MeetRec.app/Contents/Resources/process.sh RECORDING_DIR|AUDIO_FILE [mix|transcribe]

# Regenerate the README screenshots
.build/release/MeetRec --screenshots docs/screenshots
```

Right-click the panel for the Finder folder, the transcript, the log, and Quit.

## How it works

- `Sources/MeetRec/Recorder.swift` captures system audio and the microphone in one ScreenCaptureKit stream (macOS 15 added microphone capture to it) and writes each to its own file with AVFoundation.
- `Sources/MeetRec/Model.swift` holds the panel state and runs `scripts/process.sh` for mixing and transcription.
- `Sources/MeetRec/Headless.swift` is the panel-less recorder behind `meetrec start`/`record`: it records until SIGTERM or SIGINT and reports through a status file.
- `scripts/meetrec` is the command line; it launches the headless recorder with `open` and calls `process.sh` for the rest.
- `scripts/process.sh` mixes the tracks with ffmpeg, then runs `scripts/transcribe.py` through `uv run`, which installs mlx-whisper on first use.
- `scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns` from the SVG (needs `rsvg-convert`).
