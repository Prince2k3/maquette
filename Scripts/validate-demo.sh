#!/bin/bash
# Generate and compile the complete demo without signing or provider credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  macos) destination='platform=macOS' ;;
  ios) destination='generic/platform=iOS' ;;
  visionos) destination='generic/platform=visionOS' ;;
  *) echo "Usage: $0 macos|ios|visionos" >&2; exit 2 ;;
esac
# Keep an existing developer credential file untouched. CI needs only the empty template.
created_placeholder=false
if [[ ! -f Demo/MaquetteDemo/Secrets.swift ]]; then
  cp Demo/MaquetteDemo/Secrets.example.swift Demo/MaquetteDemo/Secrets.swift
  created_placeholder=true
fi
cleanup() {
  if [[ "$created_placeholder" == true ]]; then
    rm Demo/MaquetteDemo/Secrets.swift
  fi
}
trap cleanup EXIT
(cd Demo && xcodegen generate)
xcodebuild -project Demo/MaquetteDemo.xcodeproj -scheme MaquetteDemo \
  -destination "$destination" -derivedDataPath ".build/demo-validation-$1" \
  CODE_SIGNING_ALLOWED=NO build
