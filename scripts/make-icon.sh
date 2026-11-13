#!/bin/zsh
# Renders an SVG into a macOS .icns (needs rsvg-convert). Usage: make-icon.sh in.svg out.icns
set -euo pipefail
T=$(mktemp -d)/AppIcon.iconset; mkdir -p "$T"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s "$1" -o "$T/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) "$1" -o "$T/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$T" -o "$2"
