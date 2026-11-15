#!/bin/zsh
# Builds MeetRec.app. Pass --install to copy it to /Applications, link the `meetrec` CLI into
# ~/.local/bin and (re)launch the panel. --install --no-launch skips the panel.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release
APP="$ROOT/build/MeetRec.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetRec "$APP/Contents/MacOS/MeetRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/process.sh scripts/transcribe.py scripts/meetrec "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/process.sh" "$APP/Contents/Resources/meetrec"

# A real signing identity keeps the recording permissions across rebuilds; ad-hoc signing resets them.
IDENTITY="${MEETREC_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
print "built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  if [[ -f "$HOME/.config/meetrec/recording.status" ]] && pgrep -qf "MeetRec --record"; then
    print "a CLI recording is running; meetrec stop first" >&2
    exit 1
  fi
  pkill -x MeetRec 2>/dev/null || true
  rm -rf /Applications/MeetRec.app
  cp -R "$APP" /Applications/MeetRec.app
  mkdir -p "$HOME/.local/bin"
  ln -sf /Applications/MeetRec.app/Contents/Resources/meetrec "$HOME/.local/bin/meetrec"
  print "installed /Applications/MeetRec.app and ~/.local/bin/meetrec"
  if [[ "${2:-}" != "--no-launch" ]]; then
    open /Applications/MeetRec.app
    print "launched the panel"
  fi
fi
