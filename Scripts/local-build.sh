#!/bin/zsh
# Local build helper for hosts that cannot run Xcode 16 (e.g. macOS 12).
#
# The repo targets swift-tools-version 5.10 so the swift.org Swift 5.10.1
# toolchain (whose target triple is x86_64-apple-macosx12.0) can build it
# natively; CI still builds on macos-15 with Xcode 16.
#
# One-time setup on a macOS 12 host (no sudo needed):
#   curl -sL -o /tmp/swift.pkg \
#     "https://download.swift.org/swift-5.10.1-release/xcode/swift-5.10.1-RELEASE/swift-5.10.1-RELEASE-osx.pkg"
#   pkgutil --expand-full /tmp/swift.pkg ~/toolchains/swift-5.10.1
#
# Usage:  zsh Scripts/local-build.sh
#
# Note: `swift test` cannot work on this host — the macOS XCTest runtime
# ships only with full Xcode, so tests stay on CI (see AGENTS.md).
set -euo pipefail

TC="${SWIFT_510_TOOLCHAIN:-$HOME/toolchains/swift-5.10.1/Payload}"
if [[ ! -x "$TC/usr/bin/swift" ]]; then
  print -u2 "error: Swift 5.10.1 toolchain not found at $TC"
  print -u2 "Follow the one-time setup in the header of this script."
  exit 1
fi

SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
if [[ ! -d "$SDK" ]]; then
  SDK="$(xcrun --show-sdk-path)"
fi

exec env SDKROOT="$SDK" "$TC/usr/bin/swift" build --disable-sandbox
