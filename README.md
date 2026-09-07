<h1 align="center">Switcharoo</h1>

<p align="center">
  <img src="Resources/AppIcon.png" width="112" height="112" alt="Switcharoo kangaroo logo">
</p>

<p align="center">A tasteful replacement for cmd+tab &amp; cmd+space on macOS.<br>Native Swift, AppKit, and SwiftUI.</p>

<p align="center">
  <img src="assets/switcharoo-demo.gif" width="700" alt="Switcharoo: compact launcher, Finder, calculator, window switching, schedule, and timers">
</p>

## Features

- **Switch windows:** Command-Tab quick switching; Option-Tab searchable windows. Minimize, hide, or quit from the keyboard.
- **Launch apps and URLs:** app icons, learned rankings, optional pins, and contextual actions. URLs open in your default browser.
- **Arrange windows:** 40 placements and actions, multiple displays, custom sizes, gaps, saved layouts, undo/redo, and editable shortcuts.
- **Calculate:** natural-language math, units, bandwidth, dates, time zones, currency rates, CSS colors, and history. Enter copies the answer and closes the launcher. A graph workspace plots up to six functions.
- **My Schedule:** upcoming calendar events, calendar colors, search, and meeting links.
- **Timers:** multiple named timers, pause/resume, saved countdowns, and notifications.
- **Make it yours:** compact/open modes, remembered placement, alignment guides and snapping, light/dark/system appearance, and Inter when installed.


## Shortcuts

| Key | Action |
| --- | --- |
| ⌥⌘Space | Launcher (configurable) |
| ⌘Tab / ⌥Tab | Quick switch / search windows |
| ↑ ↓ / Enter / Escape | Select / open / cancel |
| ⌘K | Contextual actions |
| ⌘, | Settings |

## Build

macOS 14+, Swift command-line tools, and Accessibility permission. Calendar and notification access are requested when needed.

```sh
./setup-dev-cert.sh      # once; preserves Accessibility trust across builds
./fetch-calculator-sdk.sh
./build.sh --install
```

For a build without installing, use `./build.sh --build-only`. Verify with `./test.sh` and `./test-calculator.sh` after building.

The calculator uses proprietary SoulverCore: personal/private builds are permitted under its terms; distribution requires an appropriate vendor license. Switcharoo's source is MIT. See [third-party notices](THIRD_PARTY_NOTICES.md).

[Usage and configuration](docs/REFERENCE.md) · [Calculator coverage and limits](CALCULATOR_PARITY.md)
