#!/bin/bash
# Compile and validate a staged bundle before touching the installed app.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:---install}"
if [[ "$MODE" != --install && "$MODE" != --build-only ]]; then
  echo "Usage: ./build.sh [--build-only | --install]" >&2
  exit 2
fi
APP="/Applications/switcharoo.app"
STAGE="$PWD/.build/switcharoo.app"
IDENTITY="Switcharoo Dev"
SOULVER="$PWD/.build/dependencies/SoulverCore-3.5.1/SoulverCore.xcframework/macos-arm64_x86_64"
if [[ ! -d "$SOULVER/SoulverCore.framework" ]]; then
  echo "Run ./fetch-calculator-sdk.sh to fetch the pinned SDK for a personal/private build." >&2
  exit 1
fi
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
ditto "$SOULVER/SoulverCore.framework" "$STAGE/Contents/Frameworks/SoulverCore.framework"
cp Info.plist "$STAGE/Contents/Info.plist"
ditto Resources "$STAGE/Contents/Resources"
cp THIRD_PARTY_NOTICES.md "$STAGE/Contents/Resources/THIRD_PARTY_NOTICES.md"
swiftc -O -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  -o "$STAGE/Contents/MacOS/switcharoo.new" \
  switcharoo.swift WindowGeometry.swift AppShortcutConfiguration.swift AppShortcuts.swift WindowManager.swift WindowPreferences.swift Typography.swift WindowDiagnostics.swift ToolWindows.swift NativeWindowMoves.swift Schedule.swift CountdownState.swift Countdown.swift LauncherSearch.swift LauncherPlacement.swift LauncherGuides.swift LauncherDiagnostics.swift LauncherUsage.swift ExchangeRates.swift RateConversionModel.swift SoulverCalculator.swift CalculatorEngine.swift CalculatorHistory.swift CalculatorModel.swift CalculatorView.swift LauncherSearchField.swift LauncherInteraction.swift LauncherFocus.swift Launcher.swift \
  -F "$SOULVER" -framework SoulverCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework SwiftUI -framework EventKit -framework UserNotifications -framework JavaScriptCore
mv "$STAGE/Contents/MacOS/switcharoo.new" "$STAGE/Contents/MacOS/switcharoo"
if security find-identity 2>/dev/null | grep -F -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$STAGE/Contents/Frameworks/SoulverCore.framework"
  codesign --force --sign "$IDENTITY" "$STAGE"
else
  if [[ "$MODE" == --install && -d "$APP" ]]; then
    echo "Stable signing identity unavailable. Built bundle retained; installed app unchanged." >&2
    echo "Run with Keychain access or use --build-only for an ad-hoc development bundle." >&2
    exit 1
  fi
  codesign --force --sign - "$STAGE/Contents/Frameworks/SoulverCore.framework"
  codesign --force --sign - "$STAGE"
fi
codesign --verify --strict "$STAGE"
plutil -lint "$STAGE/Contents/Info.plist"
if [[ "$MODE" == --build-only ]]; then
  echo "Built $STAGE (installed app unchanged)"
  exit 0
fi
BACKUP="$PWD/.build/installed-backups/$(date +%Y%m%d-%H%M%S)-$$.app"
INSTALL_STAGE="/Applications/.switcharoo-install-$$.app"
mkdir -p "$(dirname "$BACKUP")"
ditto "$STAGE" "$INSTALL_STAGE"
codesign --verify --strict "$INSTALL_STAGE"
if [[ -d "$APP" ]]; then mv "$APP" "$BACKUP"; fi
if ! mv "$INSTALL_STAGE" "$APP"; then
  if [[ -d "$BACKUP" ]]; then mv "$BACKUP" "$APP"; fi
  echo "Install failed; restored the previous app." >&2
  exit 1
fi
pkill -x switcharoo 2>/dev/null || true
# LaunchServices may still consider the exiting process alive for a moment.
for attempt in {1..30}; do
  if ! pgrep -x switcharoo >/dev/null; then break; fi
  sleep 0.1
done
if ! open -n "$APP"; then
  echo "Installed $APP, but macOS could not launch it. Open the app manually." >&2
  echo "Previous build: $BACKUP" >&2
  exit 1
fi
echo "Installed $APP"
echo "Previous build: $BACKUP"
