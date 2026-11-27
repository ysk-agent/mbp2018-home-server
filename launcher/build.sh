#!/bin/sh
# Build the btrfs-vm launcher on the MacBook Pro (macOS 14+, Xcode or
# Command Line Tools with Swift 5.9+). Produces ./btrfs-vm next to this
# script, ad-hoc signed with the Virtualization entitlement.
set -eu
cd "$(dirname "$0")"

swift build -c release

BIN=.build/release/btrfs-vm
codesign --force --sign - --entitlements btrfs-vm.entitlements "$BIN"
cp "$BIN" ./btrfs-vm

echo "Built ./btrfs-vm"
./btrfs-vm --help || true
