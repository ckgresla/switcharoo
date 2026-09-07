#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the bar anchored while cycling through unmodified native captures.
magick \
  \( -delay 180 assets/launcher-compact.png \) \
  \( -delay 300 assets/launcher.png \) \
  \( -delay 350 assets/calculator.png \) \
  \( -delay 300 assets/window-switcher.png \) \
  \( -delay 450 assets/schedule.png \) \
  \( -delay 400 assets/timers.png \) \
  -resize 700x -background '#f5f5f5' -alpha remove -alpha off \
  -gravity north -splice 0x20 -extent 740x660 \
  -dither None +remap -loop 0 -layers Optimize assets/switcharoo-demo.gif
