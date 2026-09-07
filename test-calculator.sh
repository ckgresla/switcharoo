#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP_BINARY="${1:-$PWD/.build/switcharoo.app/Contents/MacOS/switcharoo}"
python3 Tests/CalculatorWorkerTests.py "$APP_BINARY"
swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" CalculatorEngine.swift SoulverCalculator.swift Tests/CalculatorEngineTests.swift -F "$PWD/.build/dependencies/SoulverCore-3.5.1/SoulverCore.xcframework/macos-arm64_x86_64" -framework SoulverCore -Xlinker -rpath -Xlinker "$PWD/.build/dependencies/SoulverCore-3.5.1/SoulverCore.xcframework/macos-arm64_x86_64" -framework JavaScriptCore -o .build/calculator-engine-tests
.build/calculator-engine-tests "$APP_BINARY"

swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" CalculatorEngine.swift SoulverCalculator.swift CalculatorModel.swift CalculatorHistory.swift ExchangeRates.swift Tests/CalculatorModelTests.swift -F "$PWD/.build/dependencies/SoulverCore-3.5.1/SoulverCore.xcframework/macos-arm64_x86_64" -framework SoulverCore -Xlinker -rpath -Xlinker "$PWD/.build/dependencies/SoulverCore-3.5.1/SoulverCore.xcframework/macos-arm64_x86_64" -framework JavaScriptCore -framework AppKit -o .build/calculator-model-tests
.build/calculator-model-tests
