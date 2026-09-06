#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -swift-version 5 -module-cache-path "$PWD/.build/module-cache" WindowGeometry.swift Tests/WindowGeometryTests.swift -o .build/window-geometry-tests
.build/window-geometry-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" CountdownState.swift Tests/CountdownTests.swift -o .build/countdown-tests
.build/countdown-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" ExchangeRates.swift RateConversionModel.swift LauncherUsage.swift Tests/ExchangeRatesTests.swift -o .build/exchange-rate-tests
.build/exchange-rate-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" LauncherPlacement.swift Tests/LauncherPlacementTests.swift -o .build/launcher-placement-tests
.build/launcher-placement-tests

swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" LauncherSearch.swift LauncherUsage.swift Tests/LauncherNameTests.swift -o .build/launcher-name-tests
.build/launcher-name-tests

swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" WindowGeometry.swift AppShortcutConfiguration.swift Tests/AppShortcutTests.swift -o .build/app-shortcut-tests
.build/app-shortcut-tests
