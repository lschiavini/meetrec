# MeetRec

A small floating panel for macOS that records a meeting (computer audio and microphone) and turns it into text.

- The panel floats over every space, can be dragged anywhere, and is excluded from screenshots, recordings and screen shares.
- Record: creates a folder named after the start time (`2026-11-11-1436`, plus the meeting name if one was typed) and saves `system.mov` (what the computer played) and `mic.mov` (your voice), then mixes them into `audio.m4a`.
- Transcribe: writes `transcript.txt` (everyone) and `transcript-mic.txt` (your microphone only) into the same folder, locally with Whisper.
- Copy name: puts `meeting: <folder name>` on the clipboard, to paste to an agent that files the meeting (see the `meeting-notes` skill in `~/.claude/skills/`).
- The list button shows every earlier meeting; picking one copies its name, and loads it for transcription if it has no text yet.
- The same list deletes a recording (to the Trash), opens the recordings folder, and changes where new recordings go.
- The x stops and saves a running recording, then closes the app.

Needs macOS 15 or later, `ffmpeg` and `uv`.

## Install

```sh
mkdir -p ~/.config/meetrec && cp config.example.json ~/.config/meetrec/config.json   # then edit the paths
./scripts/build-app.sh --install
```

The first recording asks for two permissions: Screen & System Audio Recording (that is how macOS hands out computer audio; no video is kept) and Microphone.

## Config (`~/.config/meetrec/config.json`)

| Key | Meaning |
|---|---|
| `recordingsDir` | Where recording folders go |
| `whisperModel` | mlx-whisper model |
| `vocabulary` | Names and jargon the transcriber should expect |

## Command line

```sh
# Transcribe any recording folder, or import and transcribe any audio file from elsewhere
/Applications/MeetRec.app/Contents/Resources/process.sh ~/Downloads/call.m4a

# Record five seconds without the panel and print what was captured
/Applications/MeetRec.app/Contents/MacOS/MeetRec --selftest /tmp/meetrec-selftest 5
```

Right-click the panel for the Finder folder, the transcript, the log, and Quit.
