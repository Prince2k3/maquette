#!/bin/bash
# Compile the library and consumer/test targets at the advertised deployment floor.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ios) sdk=iphoneos; triple=arm64-apple-ios18.0 ;;
  visionos) sdk=xros; triple=arm64-apple-xros2.0 ;;
  *) echo "Usage: $0 ios|visionos" >&2; exit 2 ;;
esac
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
swift build --build-tests --scratch-path ".build/validation-$1" \
  --triple "$triple" --sdk "$sdk_path"
