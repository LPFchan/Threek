#!/bin/bash
# Builds MediaRemoteAdapter.framework from the vendored CMake source, then
# stages the framework, the perl shim script, and the test client into a
# well-known location that the app bundle copies from at build time.
#
# This keeps the adapter build-from-source (no committed binaries) while
# letting XcodeGen reference the outputs as bundle resources.

set -euo pipefail

SRCROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
VENDOR_DIR="$SRCROOT_DIR/Vendor/mediaremote-adapter"
BUILD_DIR="$VENDOR_DIR/build"
OUT_DIR="$SRCROOT_DIR/Build/Adapter"

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake is required to build MediaRemoteAdapter (brew install cmake)" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
cmake -S "$VENDOR_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD_DIR" --config Release >/dev/null

# Stage outputs into a stable directory the Xcode project can reference.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$BUILD_DIR/MediaRemoteAdapter.framework" "$OUT_DIR/"
cp "$VENDOR_DIR/bin/mediaremote-adapter.pl" "$OUT_DIR/"

echo "Built adapter -> $OUT_DIR"
