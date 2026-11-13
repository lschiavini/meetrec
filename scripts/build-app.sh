#!/bin/zsh
# Builds MeetRec.app. Pass --install to copy it to /Applications and (re)launch it.
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
cp scripts/process.sh scripts/transcribe.py "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/process.sh"

# A real signing identity keeps the recording permissions across rebuilds; ad-hoc signing resets them.
IDENTITY="${MEETREC_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
print "built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MeetRec 2>/dev/null || true
  rm -rf /Applications/MeetRec.app
  cp -R "$APP" /Applications/MeetRec.app
  open /Applications/MeetRec.app
  print "installed and launched /Applications/MeetRec.app"
fi
