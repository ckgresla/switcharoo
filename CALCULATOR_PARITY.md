# Calculator parity audit — 2026-09-05

## Foundation and sources

The installed Raycast 1.104.28 bundle contains SoulverCore. Switcharoo now uses
**the vendor's independently downloaded SoulverCore 3.5.1 SDK**, not Raycast's binary.
This replaces the earlier regex/Math.js approximation for general calculations.
Math.js is retained only for graphs; Culori implements CSS Color 4 conversions.

Primary references:
- https://manual.raycast.com/calculator
- https://www.raycast.com/changelog/1-85-0
- https://www.raycast.com/changelog/macos/1-68-0
- https://www.raycast.com/changelog/macos/7
- https://www.raycast.com/changelog/macos/10
- https://github.com/soulverteam/SoulverCore
- https://github.com/Evercoder/culori

## Evidence

`Tests/CalculatorWorkerTests.py` distinguishes ten results captured directly from
Raycast from mathematical/specification fixtures. Captured comparisons include
the reported `(1GB per second ) in Mb` → `8,000 Mbit/s`, inferred bandwidth units,
bits versus bytes, ten-decimal precision, radians/degrees, and REM/PX.
No further Raycast UI automation is used following the user's request to restart it.

81 worker checks pass, including the ten exact Raycast results. The measured warm
worker round-trip median was 0.26 ms in this run (not end-to-end launch/paint latency).
Four process checks cover IPC, worker reuse, deadline termination and recovery.
Eighteen interaction checks cover typing debounce, retaining old display values while
blocking stale copy, obsolete reply rejection, currency re-evaluation, and history.

| Feature | Implementation / validation |
| --- | --- |
| Natural-language math, precedence, scientific/trig functions | Native SoulverCore; fixture coverage |
| Fractions, percentages, financial calculations, playback speeds | SDK; documented-example checks; aliases added for tip and ratio syntax |
| Dimensional units, storage, transfer rates/duration | SDK; exact bandwidth comparison and SI/IEC fixtures |
| Dates, workdays, holidays, lunar dates, city/airport timezones | SDK; fixed/dynamic cases; explicit `ldn`/`sf` aliases |
| Locale formatting, raw/formatted results, REM size, automatic units | Native settings and worker fixtures |
| Fiat / crypto currencies | SDK requests currency pairs from existing Google Finance backend; no bundled default rates allowed |
| Live transport | USD/GBP and inverse USD/BTC fetched and validated with provider timestamps |
| Color input and conversion | Culori HEX/RGB/HSL/HWB/Lab/LCH/OKLab/OKLCH with alpha and format-copy actions |
| History, pin, delete, reuse, search | Local persistence; pinned entries survive three-month pruning |
| Copy formatted/raw/question+answer, swap units, use answer | Native Actions menu; stale results cannot be copied |
| Responsive evaluation | 100 ms debounce; stable previous result; network outside calculator worker |

## Limits that must not be described as completed parity

- Ten exact comparisons plus the public feature tests do not prove every undocumented
  Raycast parser edge case or formatting option. SDK versions/settings can differ.
- Currency coverage is limited by Google Finance. Unsupported and historical rates
  report unavailable; no estimated or bundled fallback quote is silently substituted.
- History records copied/dismissed calculations, not every intermediate input; selected
  history re-evaluates live, while unselected rows show their stored result.
- The editable search field remains monochrome rather than reproducing Raycast syntax
  colors. The result uses Switcharoo's existing compact layout.
- Graphs support explicit y=f(x), six expressions and one parameter; this is not a
  full Desmos replacement.
- The HTML design prototype still has its independent JS calculator. Native parity
  applies to the native launcher, whose shortcut is configurable.
- The app's own rendered previews confirm the pins-only compact bar and the shared
  caret in light/dark appearances. Native panel regressions additionally cover
  focus restoration, unconfirmed-selection handoffs, and shared input dimensions.
  Hover and drag gestures still benefit from user acceptance testing; calculator
  unit/process checks alone cannot establish macOS window-server behavior.
