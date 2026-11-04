#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"

# Swift 6.4 CLT ships TestingMacros in a nested directory which the new build
# engine does not discover. Load that bundled plugin when this layout is present.
SWIFTC_PATH="$(xcrun --find swiftc)"
PLUGIN_ROOT="$(dirname "$SWIFTC_PATH")/../lib/swift/host/plugins"
if [[ -f "$PLUGIN_ROOT/testing/libTestingMacros.dylib" && ! -f "$PLUGIN_ROOT/libTestingMacros.dylib" ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN_ROOT/testing/libTestingMacros.dylib" "$@"
else
  swift test "$@"
fi
