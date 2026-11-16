#!/bin/bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: sign.sh APP IDENTITY ENTITLEMENTS [codesign options]" >&2
  exit 1
fi
APP="$1"
IDENTITY="$2"
ENTITLEMENTS="$3"
shift 3
OPTIONS=("$@")
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
VERSION="$SPARKLE/Versions/B"

sign() {
  codesign --force ${OPTIONS[@]+"${OPTIONS[@]}"} --sign "$IDENTITY" "$@"
}

if [ -d "$SPARKLE" ]; then
  [ -d "$VERSION/XPCServices/Installer.xpc" ] && sign "$VERSION/XPCServices/Installer.xpc"
  [ -d "$VERSION/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$VERSION/XPCServices/Downloader.xpc"
  sign "$VERSION/Autoupdate"
  sign "$VERSION/Updater.app"
  sign "$SPARKLE"
fi
[ -f "$APP/Contents/Helpers/broadway" ] && sign "$APP/Contents/Helpers/broadway"
if [ -n "$ENTITLEMENTS" ]; then
  sign --entitlements "$ENTITLEMENTS" "$APP"
else
  sign "$APP"
fi
codesign --verify --deep --strict "$APP"
