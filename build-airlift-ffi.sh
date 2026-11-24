#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUST_ROOT="$ROOT/AirCard-iOS-main/rust-core"
OUT="$ROOT/External/AirliftFFI.xcframework"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found"
  exit 1
fi

cd "$RUST_ROOT"

echo "[*] Building AirliftFFI for physical iOS..."
cargo build --release --target aarch64-apple-ios

echo "[*] Building AirliftFFI for Apple-silicon simulator..."
cargo build --release --target aarch64-apple-ios-sim

mkdir -p "$OUT/ios-arm64/Headers" "$OUT/ios-arm64-simulator/Headers"

cp "target/aarch64-apple-ios/release/libairlift_ffi.a" \
   "$OUT/ios-arm64/libairlift_ffi.a"
cp "target/aarch64-apple-ios-sim/release/libairlift_ffi.a" \
   "$OUT/ios-arm64-simulator/libairlift_ffi.a"

# Make the linked XCFramework unambiguously newer than any stale Xcode build
# products. The Erosion project links External/AirliftFFI.xcframework.
touch "$OUT/ios-arm64/libairlift_ffi.a" \
      "$OUT/ios-arm64-simulator/libairlift_ffi.a"

cp "$RUST_ROOT/include/airlift.h" "$OUT/ios-arm64/Headers/airlift.h"
cp "$RUST_ROOT/include/airlift.h" "$OUT/ios-arm64-simulator/Headers/airlift.h"

echo "[*] AirliftFFI rebuilt."
