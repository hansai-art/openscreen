#!/usr/bin/env bash
set -euo pipefail
capture_package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
capture_regression_binary="${1:-/tmp/openscreen-capture-audio-regression}"
swiftc -parse-as-library "$capture_package_root"/Sources/OpenScreenCaptureCore/*.swift \
  "$capture_package_root/RegressionTests/main.swift" -o "$capture_regression_binary"
"$capture_regression_binary"
