#!/bin/bash
set -e
cd "$(dirname "$0")"
DEST="$HOME/Applications/Thock.app"
if [ ! -d "$DEST" ] || [ "$1" = "--rebuild" ]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "Run this first: xcode-select --install"; exit 1
  fi
  pkill -x Thock 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
  cp Info.plist "$DEST/Contents/Info.plist"
  cp -R packs "$DEST/Contents/Resources/packs"
  swiftc -O -o "$DEST/Contents/MacOS/Thock" main.swift
  xattr -cr "$DEST" 2>/dev/null || true
  codesign --force --sign - -r='designated => identifier "com.local.thock"' "$DEST" 2>/dev/null || codesign --force --sign - "$DEST"
  tccutil reset ListenEvent com.local.thock >/dev/null 2>&1 || true
fi
pkill -x Thock 2>/dev/null || true
open "$DEST"
