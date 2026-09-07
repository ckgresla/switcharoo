# Switcharoo

<img src="Resources/AppIcon.png" width="80" height="80" alt="Switcharoo kangaroo logo">

A tasteful replacement for cmd+tab & cmd+space on macOS. Native Swift, AppKit, and SwiftUI.

<img src="assets/launcher.png" width="700" alt="Switcharoo launcher finding and opening Finder">

## Features

- **Switch windows:** Command-Tab quick switching; Option-Tab searchable windows. Minimize, hide, or quit from the keyboard.
- **Launch apps and URLs:** app icons, learned rankings, optional pins, and contextual actions. URLs open in your default browser.
- **Arrange windows:** 40 placements and actions, multiple displays, custom sizes, gaps, saved layouts, undo/redo, and editable shortcuts.
- **Calculate:** natural-language math, units, bandwidth, dates, time zones, currency rates, CSS colors, and history. Enter copies the answer and closes the launcher. A graph workspace plots up to six functions.
- **My Schedule:** upcoming calendar events, calendar colors, search, and meeting links.
- **Timers:** multiple named timers, pause/resume, saved countdowns, and notifications.
- **Make it yours:** compact/open modes, remembered placement, alignment guides and snapping, light/dark/system appearance, and Inter when installed.

<details>
<summary>Screenshots</summary>

**Compact launcher**

<img src="assets/launcher-compact.png" width="700" alt="Compact two-row launcher with wand, pin button, and primary action">

**Option-Tab**

<img src="assets/window-switcher.png" width="700" alt="Searchable window switcher with sample application and window titles">

**Calculator**

<img src="assets/calculator.png" width="700" alt="One gigabyte per second converted to 8,000 Mbit/s">

| My Schedule | Timers |
| --- | --- |
| <img src="assets/schedule.png" width="345" alt="Sample upcoming events with calendar colors"> | <img src="assets/timers.png" width="345" alt="Three named timers in dark mode"> |

Screenshots use native views and sample schedule, timer, and window data.

</details>

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
