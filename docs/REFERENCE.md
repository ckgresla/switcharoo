# Switcharoo reference

<img src="../Resources/AppIcon.png" width="96" height="96" alt="Switcharoo kangaroo logo">

A native macOS window switcher, window manager, and home for focused utility windows. Built with AppKit and SwiftUI, using Inter when installed and the system font otherwise.

## Switching and commands

| Key | Action |
| --- | --- |
| Option+Cmd+Space (configurable) | Open or dismiss the launcher |
| Cmd+Tab / Cmd+Shift+Tab | Quick switching; release Command to switch |
| Option+Tab / Option+Shift+Tab | Search open windows |
| Type `>` in search | Find placements, saved layouts, My Schedule, or Timer |
| Up/Down, Ctrl+K/J, Tab | Move selection |
| Enter / Escape | Open selection / cancel |
| Cmd+M / Cmd+H / Cmd+Q / Cmd+Option+Q | Minimize / hide / quit / force-quit the highlighted app |
| Cmd+, | Switcharoo Settings |

Paste an HTTP(S) URL or a bare domain into the launcher to select **Open URL**. Enter or a click opens it in the default browser; bare domains use HTTPS. Cmd+K also offers Copy URL. URLs bypass calculator evaluation and are not saved in launch history.

The primary launcher is a 700-point floating modal. The wand or Down opens commands beneath the search field; compact/open preference persists across invocations and restarts. The bar shows only explicitly pinned items; an unpinned bar stays empty. Launch counts and recency persist locally and rank both the full command list and equally relevant typed matches. Exact name matches remain first; merely highlighting a result does not count as a launch. The plus button opens a searchable pin picker (up to three); right-click and Shift+Cmd+P also pin or unpin. The compact launcher keeps two decks: a 50-point search field and a tight 40-point control row containing the wand, plus, optional pins, and primary action. Cmd+K opens searchable contextual actions with shortcut badges: open, reveal in Finder (Cmd+Enter), package contents (Option+Cmd+Enter), copy path (Option+Cmd+C), and pin/unpin. With no visible selection, Cmd+K offers bar actions: Browse Commands, Pin an Item, Switcharoo Settings, and Toggle System Appearance. The compact bar keeps these actions keyboard-only. Escape closes the action panel and restores search focus. Cmd+, opens Switcharoo Settings from the launcher, Option-Tab, or Command-Tab. Window Management is a settings subpage. My Schedule and named timers open within it. Both launcher and Option-Tab search regions are 50 points high, with vertically aligned 17-point Inter text, no idle prompt, and the same steady native caret as Option-Tab. Option-Tab has no idle title label; result icons are 20 points. Open mode includes the complete app, tool, window-command, and saved-layout catalog with arrow-key selection. The application scan also retains running apps outside the usual folders and resolves Finder directly through macOS. The wand uses the bundled Lucide `wand-sparkles` artwork. Drag an empty composer margin or the empty space in its bottom bar to reveal thirds and center guides; buttons and menu items never initiate dragging. Soft gray rounded hover states identify clickable items. Release within 18 points to snap the modal center to a guide. Its position is remembered per saved display, with a fallback when that display is disconnected.

Legacy standalone Schedule and Timer windows still appear in the switcher.  The panel has a searchable command list and an editor for each result. Closing one leaves Switcharoo running; a timer continues in the background. Cmd+W closes a tool window; Control+Cmd+F toggles native fullscreen. When a tool window is highlighted, the switcher's quit actions close that window instead of terminating Switcharoo.

## Window management

40 built-in actions cover halves, quarters, thirds, two-thirds, fourths, sixths, maximize, maximize one axis, center, edge moves, grow/shrink, display moves, fullscreen, undo/redo, and a centered 800 × 1,000 point Chat Window. Repeating a half moves to the adjacent display by default, matching the audited Raycast setting. The defaults follow the Raycast bindings used during development, including Control+Option+Left/Right, Return to maximize, and C to center.

Settings support shortcut recording, custom point or percentage sizes and offsets, nine anchors, display targeting, desktop/tile gaps, repeated-half cycling, aliases, import/export, and saved layouts. Capture records visible windows; restore matches windows in running apps by title with an ordinal fallback. Closed windows and unavailable apps are reported; they are not launched. A disconnected saved display falls back to the current display.

Settings are stored in `~/Library/Application Support/switcharoo/window-management.json`, with the preceding saved version in `.json.previous`. Invalid settings remain on disk and disable global window shortcuts until repaired. Shortcut conflicts are visible in General; disable matching bindings in Raycast, then choose **Retry Shortcuts**. Window commands remain accessible when global shortcuts are paused.

The external-window executor uses a bounded serial queue, AX timeouts, readback, and per-window undo/redo history. Switcharoo's own tool windows use AppKit on the main thread. Window switching remains independent of calendar loading and timer updates.

This is a first implementation, not a claim of full Raycast parity. It does not include drag-to-edge snapping, automatic tiling rules, moving windows between Spaces, or Raycast's full extension ecosystem. App minimum sizes and macOS fullscreen constraints still apply. Saved layouts currently exclude Switcharoo's own utility windows.

## Currency conversions

Type `100 USD in EUR`, `$100 to GBP`, or `0.1 BTC to USD` in the launcher. The native backend retrieves public Google Finance quotes using only the currency pair. Results show the provider timestamp. Fiat quotes cache for 15 minutes and crypto for one minute; failed refreshes explicitly label usable cached data. Refresh retries immediately. Enter copies the formatted answer, Cmd+Enter copies the raw number, and Shift+Cmd+Enter includes the question. These launcher submit actions then dismiss the modal and restore the previous window; pending or stale answers neither copy nor dismiss. Google's page formats can change; unsupported pairs and unverifiable quotes show an error rather than an invented rate.

The native launcher uses SoulverCore 3.5.1 for natural-language math, scientific functions, percentages, dimensional units, SI/IEC storage, bit/byte bandwidth, transfer duration, financial calculations, workdays, holidays, dates, and timezones. `(1GB per second ) in Mb` returns `8,000 Mbit/s`. Enter copies the formatted result; Cmd+Enter copies the raw value; Shift+Cmd+Enter includes the query. The Actions menu adds swapping units, using the answer as input, pinning, history, and rate refresh. Calculator Settings controls automatic units and base REM size. History is local, searchable, deduplicated, and pruned after three months except pinned entries. Calculations are saved when copied or the launcher is dismissed; selecting history re-evaluates it with current time/rates. CSS color inputs support HEX/RGB/HSL/HWB/Lab/LCH/OKLab/OKLCH, with a swatch and format-copy actions.

Open Calculator for up to six y=f(x) expressions, parameter a, pan, zoom, and saved expressions. This graph workspace is not full Desmos: implicit plots, tables, regressions, and arbitrary sliders are not implemented. Calculator parity evidence and remaining differences are listed in [calculator coverage](../CALCULATOR_PARITY.md).

A separate persistent worker hosts SoulverCore, Culori 4.0.2 for CSS colors, and Math.js 14.8.1 for graph samples. Startup warms both the worker and its parser asynchronously. A two-second request deadline kills a stuck worker and the next request restarts it. Input waits for 100 ms of idle time; complete `now`, `today`, `tomorrow`, and `yesterday` queries use 20 ms. The previous result remains visible while typing, but cannot be copied after its query changes; obsolete replies never replace the current answer. Network requests run outside the worker so they cannot block subsequent math. Escape/hotkey dismissal restores the previously focused window before ordering out the launcher; switching to another app never steals focus back.

Run `./fetch-calculator-sdk.sh` once before building. The SDK is downloaded from the vendor, checksum-verified, and kept under ignored `.build/dependencies`. Personal/private use is permitted under the vendor terms; obtain the applicable Soulver license before distributing a bundle containing it. See [third-party notices](../THIRD_PARTY_NOTICES.md).

Tool panels use monochrome controls and compact headers. Option-Tab and Command-Tab share 700-point width, 21-point corners, 36-point rows, 20-point icons, Inter typography, and neutral gray selection. Their app-name/icon/window-title layout is preserved; Command-Tab stays headerless. Launcher appearance disables AppKit's default panel animation. Catalog rankings and shortcut lists are cached and warmed when the catalog changes.

## Utility windows

**My Schedule** displays events from calendars configured in macOS. Connect calendars in the window to grant access. Choose a day, search events, filter calendars, expand details, copy details, or open recognized meeting links. This version reads events; event creation and editing remain in Calendar. No permission prompt appears merely from starting Switcharoo.

**Timers** supports presets, custom durations from one second to 24 hours, pause/resume, persisted deadlines, and local notifications. Sleep does not slow the countdown. Notifications require macOS permission; when disabled, Switcharoo plays a sound at completion while it is running. Up to 64 independent named timers can run together. Each has separate pause/resume, restart, deletion, and notification state. System notification delivery may be affected by Focus settings.

Native tool windows share `ToolWindowHost`; new utilities can register a SwiftUI view without coupling it to window enumeration or the AX executor.

## Links

- `switcharoo://show` or `switcharoo://quick`
- `switcharoo://schedule` or `switcharoo://schedule?fullscreen=true`
- `switcharoo://timer` or `switcharoo://timer?fullscreen=true`
- `switcharoo://preferences`
- `switcharoo://window?id=right-half`
- `switcharoo://layout?id=LAYOUT_UUID`
- `switcharoo://resize?width=800&height=1000&anchor=center`
- `switcharoo://snap` renders the switcher to `/tmp/switcharoo-ui.png`
- `switcharoo://login-on` / `switcharoo://login-off`

## Build and verify

Requires macOS 14+, the Swift command-line toolchain, and Accessibility permission for controlling other apps. The natural-language calculator requires the SoulverCore SDK; Math.js and Culori are bundled JavaScript dependencies.

```sh
./setup-dev-cert.sh  # once: stable signing identity preserves Accessibility trust
./fetch-calculator-sdk.sh
./test.sh            # geometry, settings, timers, placement, rates, and shortcuts
./build.sh --build-only
./build.sh --install
```

The build compiles and verifies `.build/switcharoo.app` before installation. Installing preserves the previous app in `.build/installed-backups/`. Installation over an existing app requires the stable `Switcharoo Dev` signing identity; a build-only run can use an ad-hoc signature when that identity is unavailable. Restore a backup app to `/Applications/switcharoo.app` to roll back the binary.

`Tests/WindowFixture.swift` and `--wm-smoke-test` provide an opt-in native AX test against a disposable fixture app, with independent bounds readback. `--tools-preview` renders light/dark Schedule previews with labeled example events. Neither mode starts global switcher interception.

MIT. See [third-party notices](../THIRD_PARTY_NOTICES.md) for the Rectangle implementation reference and font notes.

### Calculator validation

After `./build.sh --build-only`, run `./test-calculator.sh` for worker calculations and process recovery. Pass an installed executable path as the first argument to test that bundle instead. The worker tests exercise the installed native SDK and bundled JavaScriptCore runtime. Interaction tests cover 20/100 ms debounce, stable results, cancellation, currency orchestration, and persistent history.

The compact composer is the saved placement anchor. Expansion preserves its screen
coordinates: normally results grow below it, while low placements grow above it.
When neither side fits the full content, results scroll within the available space
instead of pushing the bar. Direction stays stable across queries. Upward lists put
the highest-ranked item nearest the input, with arrow navigation matching that order.
Dragging and alignment guides snap the composer rather than the expanded rectangle.

My Schedule shows eight days grouped by date, with an upcoming-event summary, title filtering, arrow navigation, and event detail disclosure. Calendar markers use EventKit calendar color metadata.

Search for `Toggle System Appearance` to switch macOS light/dark mode. Switcharoo also has persistent `Switcharoo Appearance: System`, `Light`, and `Dark` commands. System uses live AppKit inheritance; toggling macOS never replaces that preference with a fixed theme. The system command uses System Events and macOS may request Automation access on first use.

Shortcut badges in Settings are clickable recorders. Press a chord to apply an app shortcut immediately; Escape cancels. Right-click an app binding for Reset Shortcut. Window Management list badges also record directly into the draft; Save applies those changes. Forward/reverse switcher chords reserve Shift for reverse cycling. Conflicting app/window bindings and shortcuts claimed by another app are rejected with the old app configuration restored. App bindings persist in the `app.shortcuts` preference. All Switcharoo global shortcuts pause while recording; losing focus ends recording.


### Focus and native regression checks

Opening the launcher from Option-Tab cancels the unconfirmed selection. Escape
returns to the application/window that was focused before entering Switcharoo.
Changing the highlighted row never changes this return target. Dismissing the
switcher clears its rows, selection, and quick-switch state; late callbacks from a
hidden switcher cannot commit or cancel another window. Explicit Enter or row clicks
still switch windows; Command-Tab retains release-to-commit behavior.

Opt-in checks below briefly open native Switcharoo panels and restore focus. Avoid
interacting with the switchers during their short runs. The results are written to
`/tmp/switcharoo-focus-regression.json` and
`/tmp/switcharoo-focus-handoff-regression.json` respectively.

```sh
open -n .build/switcharoo.app --args --focus-regression
open -n .build/switcharoo.app --args --focus-handoff-regression
```

The factory launcher binding remains Option+Command+Space. Click its binding in
Settings to choose Command+Space once it is free from other launchers or Spotlight.

## Refresh screenshots

After building, run `.build/switcharoo.app/Contents/MacOS/switcharoo --readme-preview`.
This renders native views offscreen without registering shortcuts or taking focus.
Launcher preferences are isolated; calendar, timer, and window content use sample data.
Captures are written to `/tmp/switcharoo-readme-*.png` and
`/tmp/switcharoo-style-{option,command}-tab.png`. Review them before replacing the
README images in `assets/`.
