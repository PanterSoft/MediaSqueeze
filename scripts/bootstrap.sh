#!/usr/bin/env bash
# Generates MediaSqueeze.xcodeproj from project.yml and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen via Homebrew…"
    brew install xcodegen
  else
    echo "XcodeGen is required: https://github.com/yonaskolb/XcodeGen#installing" >&2
    exit 1
  fi
fi

if [[ "${1:-}" == "--no-open" ]]; then
  make generate
else
  make open
fi
