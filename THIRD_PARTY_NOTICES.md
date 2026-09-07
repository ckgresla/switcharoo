# Implementation references

Switcharoo's window manager is a native implementation, with no runtime dependency on Rectangle or Raycast. The cross-display size/position/size sequence in `WMExecutor.apply` follows the approach documented in Rectangle's `AccessibilityElement.setFrame`. Rectangle's Accessibility and window-mover sources were consulted for macOS behavior and edge cases.

Source: https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift

MIT License

Copyright (c) 2019-2026 Ryan Hanson
Based on the Spectacle app, Copyright (c) 2017 Eric Czarny eczarny@gmail.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Inter is used when installed on the system. Font files are not bundled.

## Lucide icon

The launcher wand is Lucide `wand-sparkles`, bundled as an SVG from https://github.com/lucide-icons/lucide/blob/main/icons/wand-sparkles.svg. Its ISC license is included in Resources/LUCIDE-LICENSE and the installed bundle.

## Math.js

The native calculator bundles Math.js 14.8.1 (https://mathjs.org/). Apache 2.0 and bundled dependency notices are included in Resources/MATHJS-LICENSE and Resources/math.js.LICENSE.txt.

## SoulverCore (personal/private build)

The natural-language calculator uses the vendor's SoulverCore 3.5.1 binary SDK,
obtained from https://github.com/soulverteam/SoulverCore/releases/tag/3.5.1.
It is not copied from Raycast. The SDK is proprietary, not MIT/Apache licensed.
The vendor permits personal/private use; public or commercial distribution
requires an appropriate license from Soulver (including its attribution option).
See https://github.com/soulverteam/SoulverCore for current terms and contact details.
The SDK download remains under ignored `.build/dependencies`; do not publish an
app containing it without obtaining the applicable distribution license.
Math.js is retained for graph evaluation only.

## Culori

CSS color parsing and conversions use Culori 4.0.2 (MIT), from the official npm
package published by https://github.com/Evercoder/culori. The npm SHA-512 integrity
was verified before vendoring. Its license is bundled in Resources/CULORI-LICENSE.
