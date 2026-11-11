#!/bin/zsh
# Turns a recording into text: mix the tracks, then transcribe.
#
# usage: process.sh RECORDING_DIR [mix|transcribe]
#        process.sh AUDIO_FILE    [mix|transcribe]      (imports the file as a new recording first)
#
# Lines starting with "STAGE: " are progress messages for the app.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

HERE="${0:A:h}"
CONFIG="${MEETREC_CONFIG:-$HOME/.config/meetrec/config.json}"
TARGET="${1:?usage: process.sh RECORDING_DIR|AUDIO_FILE [mix|transcribe]}"
STAGE="${2:-transcribe}"

[[ -f "$CONFIG" ]] || { print -r -- "FAIL: missing $CONFIG (see config.example.json)"; exit 2; }

# Reads one key from the config; prints the fallback when the key is absent.
cfg() { plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null || print -r -- "${2:-}"; }

expand() { print -r -- "${1/#\~/$HOME}"; }

if [[ -f "$TARGET" ]]; then
  root=$(expand "$(cfg recordingsDir)")
  name="${TARGET:t:r}"
  slug=$(print -r -- "$name" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//; s/-$//')
  DIR="$root/$(date -r "$TARGET" +%Y-%m-%d-%H%M)-$slug"
  mkdir -p "$DIR"
  if [[ ! -f "$DIR/audio.m4a" ]]; then
    ffmpeg -v error -y -i "$TARGET" -vn -c:a aac -b:a 96k "$DIR/audio.m4a"
  fi
  if [[ ! -f "$DIR/meta.json" ]]; then
    title=${name//\"/}
    print -r -- "{\"title\": \"$title\", \"startedAt\": \"$(date -r "$TARGET" +%Y-%m-%dT%H:%M:%S%z)\", \"importedFrom\": \"${TARGET//\"/}\"}" > "$DIR/meta.json"
  fi
else
  DIR="${TARGET:A}"
fi
[[ -d "$DIR" ]] || { print -r -- "FAIL: no such recording: $TARGET"; exit 2; }

exec > >(tee -a "$DIR/process.log") 2>&1
print -r -- "--- $(date '+%Y-%m-%d %H:%M:%S') stage=$STAGE dir=$DIR"
trap 'print -r -- "FAIL: stopped at line $LINENO"' ZERR

track_start() { plutil -extract "tracks.$1.firstPTS" raw -o - "$DIR/meta.json" 2>/dev/null || print 0; }

mix() {
  [[ -f "$DIR/audio.m4a" ]] && return 0
  print -r -- "STAGE: Mixing audio"
  local sys="$DIR/system.mov" mic="$DIR/mic.mov"
  [[ -s "$sys" ]] || sys=""
  [[ -s "$mic" ]] || mic=""
  if [[ -n "$sys" && -n "$mic" ]]; then
    # The two tracks start a moment apart; delay the later one so they line up.
    local s m
    s=$(track_start system); m=$(track_start mic)
    integer sys_delay=0 mic_delay=0
    if (( m > s )); then (( mic_delay = (m - s) * 1000 )); else (( sys_delay = (s - m) * 1000 )); fi
    ffmpeg -v error -y -i "$sys" -i "$mic" -filter_complex \
      "[0:a]adelay=${sys_delay}:all=1[a];[1:a]adelay=${mic_delay}:all=1[b];[a][b]amix=inputs=2:duration=longest:normalize=0[out]" \
      -map "[out]" -c:a aac -b:a 96k "$DIR/audio.tmp.m4a"
  elif [[ -n "$sys$mic" ]]; then
    ffmpeg -v error -y -i "${sys:-$mic}" -vn -c:a aac -b:a 96k "$DIR/audio.tmp.m4a"
  else
    print -r -- "FAIL: no audio tracks in $DIR"; exit 3
  fi
  mv "$DIR/audio.tmp.m4a" "$DIR/audio.m4a"
}

transcribe() {
  local model vocabulary
  model=$(cfg whisperModel "mlx-community/whisper-large-v3-turbo")
  vocabulary=$(cfg vocabulary "")
  if [[ ! -s "$DIR/transcript.txt" ]]; then
    print -r -- "STAGE: Transcribing"
    uv run --quiet "$HERE/transcribe.py" "$DIR/audio.m4a" "$DIR/transcript.tmp.txt" --model "$model" --vocabulary "$vocabulary"
    mv "$DIR/transcript.tmp.txt" "$DIR/transcript.txt"
  fi
  # The microphone alone shows which lines are the user's own.
  if [[ -s "$DIR/mic.mov" && -s "$DIR/system.mov" && ! -f "$DIR/transcript-mic.txt" ]]; then
    print -r -- "STAGE: Transcribing your mic"
    local s m offset=0
    s=$(track_start system); m=$(track_start mic)
    (( m > s )) && (( offset = m - s ))
    uv run --quiet "$HERE/transcribe.py" "$DIR/mic.mov" "$DIR/transcript-mic.tmp.txt" --model "$model" --vocabulary "$vocabulary" --offset "$offset"
    mv "$DIR/transcript-mic.tmp.txt" "$DIR/transcript-mic.txt"
  fi
}

case "$STAGE" in
  mix) mix ;;
  transcribe|all) mix; transcribe ;;
  *) print -r -- "FAIL: unknown stage $STAGE"; exit 2 ;;
esac
print -r -- "STAGE: Done"
