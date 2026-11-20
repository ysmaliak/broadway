#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary — and, when
# asked, the disk image it installs from.
#
#   ./build.sh                 debug-free release build, ad-hoc signed: runs here
#   SEARCH_DEV=1 ./build.sh    the same as a dev build: yellow icon, named for
#                              the branch (Broadway-split-view from
#                              claude/split-view-4a6927)
#   SEARCH_DEV=1 SEARCH_FEATURE=name ./build.sh
#                              the same, named Broadway-name
#   ./build.sh release dmg     + build/Broadway.dmg, signed with Developer ID if
#                                there is one in the keychain
#   ./build.sh release ship    + notarised and stapled
#
#   SEARCH_ARCH=x86_64 ./build.sh release ship
#                              the same for Intel Macs, into build/intel/
#
# SwiftPM builds the executable, and a macOS app bundle is just a folder with
# a plist and the binary in the right place.
#
# Two builds, each for one kind of Mac: Apple Silicon, in build/, and Intel,
# in build/intel/. A single universal app would have weighed twice as much
# (10.9 MB of binary instead of 5.4). SEARCH_ARCH picks the chip; without it, the Mac's own.
#
# "dmg" lays the disk image's window out with dmgbuild, installed into .build
# on first use (Python 3 and a network, once).
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
ARCH="${SEARCH_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64) OUT="build"; SUBFOLDER="" ;;
  x86_64) OUT="build/intel"; SUBFOLDER="/intel" ;;
  *) echo "SEARCH_ARCH is arm64 or x86_64, not “$ARCH”" >&2; exit 1 ;;
esac
APP="$OUT/Broadway.app"
NAME="Broadway"
# Asked for with SEARCH_DEV=1, a dev build, on a yellow plate and named for
# the feature it's built from: "Broadway-split-view" in the menu bar, the Dock
# and ⌘Tab, so it's never taken for the installed app beside it, or for the
# dev build from another worktree. Only the name people see changes. The
# bundle id stays, so it shares the real app's settings, and so does the
# folder, build/Broadway.app, which fresh.sh and the tests open. What goes in a
# DMG is never one.
case "${SEARCH_DEV:-}" in
  0|1) DEV="$SEARCH_DEV" ;;
  "") DEV=0 ;;
  *) echo "SEARCH_DEV is 0 or 1, not “$SEARCH_DEV”" >&2; exit 1 ;;
esac
[ "$STEP" != "app" ] && [ "$DEV" = 1 ] && { echo "a dev build doesn't go in a DMG" >&2; exit 1; }
RELEASE=0
[ "$STEP" != "app" ] && RELEASE=1
BUILD_ENV="${BROADWAY_BUILD_ENV:-$HOME/.config/broadway/build.env}"
TEAM="" SIGN_IDENTITY="" STABLE_IDENTITY="" NOTARY_PROFILE=""
SIGNING_KEYCHAIN="" SIGNING_KEYCHAIN_ACCOUNT="" SIGNING_KEYCHAIN_SERVICE=""
if [ -f "$BUILD_ENV" ]; then
  . "$BUILD_ENV"
else
  echo "signing: no $BUILD_ENV, so this build is signed ad-hoc (see build.env.example)"
fi
SIGN_IDENTITY="${SEARCH_SIGN_IDENTITY:-$SIGN_IDENTITY}"
STABLE_IDENTITY="${SEARCH_STABLE_IDENTITY:-$STABLE_IDENTITY}"
NOTARY_PROFILE="${SEARCH_NOTARY_PROFILE:-$NOTARY_PROFILE}"
FEED="https://broadwaybrowser.com/appcast.xml"
FEED_KEY="nxl83C8RF5QYop3e8+ObGP7dHn4HZ3NanZmdjG8HPME="
SHOWN="$NAME"
if [ "$DEV" = 1 ]; then
  # The feature: SEARCH_FEATURE, or the branch's last part, without the
  # six-character hash a worktree's name ends in (claude/split-view-4a6927
  # is split-view). A hash has a digit in it; a word like "decade" doesn't.
  FEATURE="${SEARCH_FEATURE:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
  FEATURE="${FEATURE##*/}"
  if [[ "$FEATURE" =~ ^(.+)-([0-9a-f]{6})$ ]]; then
    STEM="${BASH_REMATCH[1]}" HASH="${BASH_REMATCH[2]}"
    [[ "$HASH" =~ [0-9] ]] && FEATURE="$STEM"
  fi
  # Only what's safe in a name and in InfoPlist.strings.
  FEATURE="$(printf '%s' "$FEATURE" | tr -cd 'A-Za-z0-9._-')"
  case "$FEATURE" in
    ""|HEAD) SHOWN="$NAME Dev" ;;   # no branch to name it for
    *) SHOWN="$NAME-$FEATURE" ;;
  esac
fi
ICONS="ink night day volt citrus"
case "${SEARCH_ICON:-}" in
  night|day|ink|volt|citrus) ICON="$SEARCH_ICON"; ICONFROM="SEARCH_ICON" ;;
  "")
    ICON="ink"; ICONFROM="the default"
    if [ "$STEP" = "app" ]; then
      SAVED="$(defaults read com.ysmaliak.broadway app.icon 2>/dev/null || true)"
      case "$SAVED" in night|day|ink|volt|citrus) ICON="$SAVED"; ICONFROM="Settings" ;; esac
    fi
    ;;
  *) echo "SEARCH_ICON is ink, night, day, volt or citrus, not “${SEARCH_ICON}”" >&2; exit 1 ;;
esac
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
MINIMUM="27.0"

# -Osize for a release: 14% less binary (5.39 → 4.65 MB) at the same speed —
# launch 337 against 338 ms, a scroll frame 0.26 against 0.25 ms, a key typed
# 0.41 ms either way, measured interleaved on 1.0.4 (27 Sep 2026).
SWIFTFLAGS=(-c "$CONFIG" --arch "$ARCH")
[ "$CONFIG" = "release" ] && SWIFTFLAGS+=(-Xswiftc -Osize -Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
swift build "${SWIFTFLAGS[@]}"
BINARY="$(swift build "${SWIFTFLAGS[@]}" --show-bin-path)/Search"
[ "$(lipo -archs "$BINARY")" = "$ARCH" ] || { echo "$BINARY is not a $ARCH binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
mkdir -p "$APP/Contents/Helpers"
cp "$(dirname "$BINARY")/broadway" "$APP/Contents/Helpers/broadway"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_FROM=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FROM" ] || { echo "Sparkle.framework is not at $SPARKLE_FROM" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FROM" "$SPARKLE"
for EXTRA in Headers PrivateHeaders Modules; do
  rm -rf "$SPARKLE/$EXTRA" "$SPARKLE/Versions/B/$EXTRA"
done
for PIECE in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater \
  XPCServices/Installer.xpc/Contents/MacOS/Installer XPCServices/Downloader.xpc/Contents/MacOS/Downloader; do
  lipo -thin "$ARCH" "$SPARKLE/Versions/B/$PIECE" -output "$SPARKLE/Versions/B/$PIECE.thin"
  mv "$SPARKLE/Versions/B/$PIECE.thin" "$SPARKLE/Versions/B/$PIECE"
done
otool -l "$APP/Contents/MacOS/$NAME" | grep -q "path @executable_path/../Frameworks " \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$NAME" 2>/dev/null
# The binary says which SDK it was built with, and AppKit draws the app the
# way that SDK's macOS drew it: built with the macOS 27 SDK, a Mac on 27 gets
# 27's window buttons and controls; said to be built with an older one, it
# gets that one's. Swift Build, SwiftPM's default since Xcode 27, writes the
# oldest macOS the app runs on in both places, and the SDK it really was built
# with is put back here; the oldest macOS stays as it is.
SDK="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos "$MINIMUM" "$SDK" -replace \
  -output "$APP/Contents/MacOS/$NAME.sdk" "$APP/Contents/MacOS/$NAME"
mv "$APP/Contents/MacOS/$NAME.sdk" "$APP/Contents/MacOS/$NAME"
# The AppleScript dictionary (Scripting.swift): read-only, tabs' addresses
# and titles. The plist below points to it.
cp Broadway.sdef "$APP/Contents/Resources/"
cp LICENSE THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Fonts/*.woff2 "$APP/Contents/Resources/Fonts/"

# Symbols stay out of the app. The linker leaves every function's name and a
# map back to the source in the binary — 15,000 entries, more than half of
# what the app weighed (6.5 MB of binary, 2.7 without them), and nothing the
# app reads while it runs. They are kept beside the build instead, as a dSYM
# that turns the addresses in a crash report back into names (Console, or
# atos -o build/Search.app.dSYM/Contents/Resources/DWARF/Search).
if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$BINARY" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -S -x "$APP/Contents/MacOS/$NAME"
  strip -S -x "$APP/Contents/Helpers/broadway"
fi

# The icon, drawn fresh each time — it is thirty lines of Swift, not an asset
# to keep in step with anything.
ICONSET="build/AppIcon.iconset"
ICONDOC="build/AppIcon.icon"
rm -rf "$ICONSET" "$ICONDOC"
OTHERS=()
DRAW="build/icon-drawing.swift"
cat Sources/Search/BroadwayMap.swift Icon/icon.swift > "$DRAW"
for OTHER in $ICONS; do
  [ "$OTHER" = "$ICON" ] && continue
  rm -rf "build/AppIcon-$OTHER.iconset"
  SEARCH_DEV="$DEV" SEARCH_ICON="$OTHER" swift "$DRAW" "build/AppIcon-$OTHER.iconset" > /dev/null &
  OTHERS+=($!)
done
SEARCH_DEV="$DEV" SEARCH_ICON="$ICON" swift "$DRAW" "$ICONSET" "$ICONDOC" > /dev/null
for DRAWING in "${OTHERS[@]}"; do wait "$DRAWING"; done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Icons"
for OTHER in $ICONS; do
  SET="build/AppIcon-$OTHER.iconset"
  [ "$OTHER" = "$ICON" ] && SET="$ICONSET"
  cp "$SET/icon_512x512@2x.png" "$APP/Contents/Resources/Icons/$OTHER.png"
  rm -rf "$SET"
done
# The Dock's Dark, Clear and Tinted styles read the icon from an asset catalog
# compiled from the Icon Composer document. Only Assets.car is kept, not
# actool's own .icns: the one above goes on being the disk image's icon.
ICONNAME=""
ICONCAR="build/AppIcon.car"
rm -rf "$ICONCAR"
mkdir -p "$ICONCAR"
# Full paths: actool hands the document to a helper that runs elsewhere, and
# with "build/…" it finds nothing ("Icon export exited with status 255").
if xcrun actool "$PWD/$ICONDOC" --compile "$PWD/$ICONCAR" --platform macosx \
     --minimum-deployment-target "$MINIMUM" --app-icon AppIcon --optimization space \
     --output-partial-info-plist "$PWD/$ICONCAR/partial.plist" > /dev/null 2>&1 \
   && [ -f "$ICONCAR/Assets.car" ]; then
  cp "$ICONCAR/Assets.car" "$APP/Contents/Resources/Assets.car"
  ICONNAME="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "note: actool from Xcode 26 didn't compile the icon — no Dark or Tinted style this time" >&2
fi
rm -rf "$ICONCAR" "$ICONDOC"

UPDATES=""
if [ "$RELEASE" = 1 ]; then
  KEPT_KEY="$HOME/.config/broadway/sparkle-ed25519.pub"
  if [ -f "$KEPT_KEY" ] && [ "$(tr -d '[:space:]' < "$KEPT_KEY")" != "$FEED_KEY" ]; then
    echo "updates: the public key in build.sh is not the one in $KEPT_KEY" >&2
    exit 1
  fi
  if [ "$(printf '%s' "$FEED_KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" != 32 ]; then
    echo "updates: the public key in build.sh is not an EdDSA key" >&2
    exit 1
  fi
  UPDATES="<key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$FEED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>14400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUAllowsAutomaticUpdates</key><false/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.ysmaliak.broadway</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>BroadwayAppIcon</key><string>$ICON</string>
  $ICONNAME
  $UPDATES
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License. Based on Search © Office Commun</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>Broadway.sdef</string>
  <!-- Owning http and https is what sends a link clicked in Mail here.
       Appearing in Desktop & Dock → Default web browser also needs the
       XHTML document type below. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.ysmaliak.broadway.drag.folder</string>
      <key>UTTypeDescription</key><string>Broadway folder</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.ysmaliak.broadway.drag.bookmark</string>
      <key>UTTypeDescription</key><string>Broadway bookmark</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
    <!-- macOS only lists an app under Desktop & Dock → Default web browser
         when it claims public.xhtml as well as public.html. http and https
         alone, which Broadway already had, are not enough. -->
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
    <!-- What a browser shows besides pages, listed under the Finder's Open
         With (#524): a PDF, a picture, plain text (code and logs conform to
         it), JSON. Alternate, so Broadway is offered there and never becomes
         what opens them on a double-click. Pictures by name rather than
         public.image, which takes in SVG: an SVG can carry a script, and
         opened from the Finder it would run with its folder to read. -->
    <dict>
      <key>CFBundleTypeName</key><string>Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string><string>public.png</string><string>public.jpeg</string><string>com.compuserve.gif</string><string>public.heic</string><string>org.webmproject.webp</string><string>public.tiff</string><string>public.plain-text</string><string>public.json</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSUserActivityTypes</key>
  <array><string>NSUserActivityTypeBrowsingWeb</string></array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- A browser is asked for these by the pages it shows, not by itself. macOS
       still wants a sentence to put in its own prompt, and touching the APIs
       without one is a crash rather than a refusal. -->
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Broadway asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone. Broadway asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <!-- Location: the first key is the one macOS has always read; the second
       is the one CoreLocation's requestWhenInUseAuthorization documents.
       Same sentence in both. -->
  <key>NSLocationUsageDescription</key>
  <string>Websites you visit can ask for your location. Broadway asks you each time a site does, unless you choose Always allow for it; Settings › Privacy forgets those choices.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Websites you visit can ask for your location. Broadway asks you each time a site does, unless you choose Always allow for it; Settings › Privacy forgets those choices.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Broadway reads your calendars to show your next meeting, count down to it and join it. They stay on this Mac.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Broadway reads your calendars to show your next meeting, count down to it and join it. They stay on this Mac.</string>
  <key>NSContactsUsageDescription</key>
  <string>Broadway shows the photos of people in your meetings from Contacts, looked up by email on this Mac. Nothing is sent anywhere.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST
# A dev build's name, as a localised one: under the icon in the Dock, in
# ⌘Tab and in Finder, macOS shows the bundle's folder name otherwise. The
# plain names above stay "Broadway", matching the folder, since a folder named
# otherwise reads to macOS as renamed by hand, and then the folder wins.
if [ "$DEV" = 1 ]; then
  mkdir -p "$APP/Contents/Resources/en.lproj"
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$SHOWN" "$SHOWN" \
    > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
  /usr/libexec/PlistBuddy -c "Add :LSHasLocalizedDisplayName bool true" "$APP/Contents/Info.plist"
fi

if [ "$RELEASE" = 1 ] && [ -n "$SIGNING_KEYCHAIN" ] && [ -f "$SIGNING_KEYCHAIN" ]; then
  security unlock-keychain -p "$(security find-generic-password -a "$SIGNING_KEYCHAIN_ACCOUNT" -s "$SIGNING_KEYCHAIN_SERVICE" -w)" "$SIGNING_KEYCHAIN"
fi
KEYCHAIN_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
IDENTITY="$SIGN_IDENTITY"
if [ -z "$IDENTITY" ] && [ -n "$TEAM" ]; then
  IDENTITY="$(grep -o "\"Developer ID Application: [^\"]*($TEAM)\"" <<< "$KEYCHAIN_IDENTITIES" | head -1 | tr -d '"' || true)"
fi
team_of() {
  security find-certificate -a -Z -p 2>/dev/null | awk -v want="$1" '
    /^SHA-1 hash:/ { on = ($3 == want) }
    on && /BEGIN CERTIFICATE/ { pem = 1 }
    on && pem { print }
    on && pem && /END CERTIFICATE/ { exit }' \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F'= ' '/organizationalUnitName/ { print $2; exit }'
}
ENTITLEMENTS="Search.entitlements"
PASSKEYS=0
if [ -f "Search.provisionprofile" ]; then
  PROFILE_PLIST="$(mktemp -t broadway-profile)"
  security cms -D -i "Search.provisionprofile" > "$PROFILE_PLIST"
  PROFILE_GRANT="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.web-browser.public-key-credential" "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_APP="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PROFILE_PLIST" 2>/dev/null || true)"
  if [ "$PROFILE_GRANT" != "true" ] || [ "${PROFILE_APP#*.}" != "com.ysmaliak.broadway" ] || [ -z "$PROFILE_TEAM" ]; then
    echo "passkeys: Search.provisionprofile doesn't grant the browser entitlement to com.ysmaliak.broadway (it is for ${PROFILE_APP#*.}): building without passkeys" >&2
  else
    PASSKEYS=1
  fi
elif [ "$STEP" = "ship" ]; then
  echo "passkeys: no Search.provisionprofile here, so this release has no passkey entitlement" >&2
fi
if [ "$PASSKEYS" = 1 ]; then
  PROFILE_ALL="$(plutil -extract ProvisionsAllDevices raw "$PROFILE_PLIST" 2>/dev/null || true)"
  if [ "$PROFILE_ALL" != "true" ] && [ "$RELEASE" = 1 ]; then
    echo "passkeys: Search.provisionprofile is a development profile, which opens on its own Macs only: left out of a public build, and passkeys with it" >&2
    PASSKEYS=0
  elif [ "$PROFILE_ALL" != "true" ]; then
    THIS_MAC="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2}')"
    if ! plutil -extract ProvisionedDevices xml1 -o - "$PROFILE_PLIST" 2>/dev/null | grep -q "<string>$THIS_MAC</string>"; then
      echo "passkeys: Search.provisionprofile is a development profile without this Mac ($THIS_MAC): add the Mac to it in the developer portal and download it again" >&2
      exit 1
    fi
  fi
fi
if [ "$PASSKEYS" = 1 ]; then
  PROFILE_CERTS="$(plutil -extract DeveloperCertificates raw "$PROFILE_PLIST" 2>/dev/null || echo 0)"
  PROFILE_IDENTITY=""
  for ((i = 0; i < PROFILE_CERTS; i++)); do
    HASH="$(plutil -extract "DeveloperCertificates.$i" raw "$PROFILE_PLIST" | base64 -d | shasum -a 1 | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
    LINE="$(grep -F "$HASH" <<< "$KEYCHAIN_IDENTITIES" | head -1 || true)"
    [ -z "$LINE" ] && continue
    if [ -z "$SIGN_IDENTITY" ] || grep -qF "$SIGN_IDENTITY" <<< "$LINE"; then
      PROFILE_IDENTITY="$HASH"
      break
    fi
  done
  if [ -z "$PROFILE_IDENTITY" ]; then
    echo "passkeys: the keychain has no certificate that Search.provisionprofile allows${SIGN_IDENTITY:+ and that matches “${SIGN_IDENTITY}”} (move the profile away to build without passkeys or Apple Passwords)" >&2
    exit 1
  fi
  IDENTITY="$PROFILE_IDENTITY"
  echo "passkeys: signing with $(sed -E 's/^[^"]*"([^"]*)".*/\1/' <<< "$(grep -F "$IDENTITY" <<< "$KEYCHAIN_IDENTITIES" | head -1)")"
  cp "Search.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$(mktemp -t broadway-entitlements)"
  cp "Search.passkeys.entitlements" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM" "$ENTITLEMENTS"
  echo "passkeys: profile embedded"
fi
if [ "$RELEASE" = 0 ] && [ "$PASSKEYS" != 1 ] && [ -z "$SIGN_IDENTITY" ] && [ -n "$STABLE_IDENTITY" ]; then
  ./sign.sh "$APP" "$STABLE_IDENTITY" ""
  echo "signed as: $STABLE_IDENTITY (stable, for privacy grants)"
elif [ -n "$IDENTITY" ]; then
  ./sign.sh "$APP" "$IDENTITY" "$ENTITLEMENTS" --timestamp --options runtime
  echo "signed as: $IDENTITY"
elif [ "$RELEASE" = 1 ] && [ -n "$TEAM" ]; then
  INTERIM=""
  for HASH in $(awk '/"Apple Development: / { print $2 }' <<< "$KEYCHAIN_IDENTITIES"); do
    if [ "$(team_of "$HASH")" = "$TEAM" ]; then
      INTERIM="$HASH"
      break
    fi
  done
  if [ -n "$INTERIM" ]; then
    ./sign.sh "$APP" "$INTERIM" "$ENTITLEMENTS" --timestamp --options runtime
    echo "signed as: $(sed -E 's/^[^"]*"([^"]*)".*/\1/' <<< "$(grep -F "$INTERIM" <<< "$KEYCHAIN_IDENTITIES" | head -1)")"
    echo "no Developer ID certificate of team $TEAM: this build is not notarised, and another Mac opens it only after Open Anyway in System Settings › Privacy & Security" >&2
  else
    ./sign.sh "$APP" - ""
    echo "no certificate of team $TEAM at all: signed ad-hoc, and another Mac opens it only after Open Anyway in System Settings › Privacy & Security" >&2
  fi
else
  ./sign.sh "$APP" - ""
fi

if [ "$RELEASE" = 1 ]; then
  SAID_FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)"
  SAID_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$SAID_FEED" != "$FEED" ] || [ "$SAID_KEY" != "$FEED_KEY" ]; then
    echo "updates: the app's Info.plist does not carry the feed and its key" >&2
    exit 1
  fi
  [ "$ICON" = "ink" ] || [ -n "${SEARCH_ICON:-}" ] || { echo "public build: the icon is $ICON, not the default" >&2; exit 1; }
  LEAKS="$(grep -rlE "/Users/|$HOME" "$APP" 2>/dev/null || true)"
  if [ -n "$LEAKS" ]; then
    echo "public build: a path of this Mac is in:" >&2
    echo "$LEAKS" >&2
    exit 1
  fi
  if [ "$PASSKEYS" != 1 ] && [ -e "$APP/Contents/embedded.provisionprofile" ]; then
    echo "public build: a provisioning profile is embedded without its entitlement" >&2
    exit 1
  fi
fi

echo "built: $APP as $SHOWN ($VERSION, $ARCH, build $BUILD)"
echo "icon: $ICON, from $ICONFROM"
[ "$STEP" = "app" ] && exit 0

DMG="$OUT/$NAME.dmg"
ART="build/installer"
rm -rf "$ART" "$DMG"
mkdir -p "$ART"
DMGBUILD=".build/dmgbuild/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
  { python3 -m venv .build/dmgbuild && .build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
cat Sources/Search/BroadwayMap.swift Installer/background.swift > "$ART/background.swift"
if [ -x "$DMGBUILD" ] \
  && swift "$ART/background.swift" "$ART" Installer/layout.json >/dev/null \
  && tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
then
  "$DMGBUILD" -s Installer/dmg.py \
    -D app="$APP" -D layout=Installer/layout.json \
    -D background="$ART/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "$NAME" "$DMG" >"$ART/dmgbuild.log" 2>&1 || { cat "$ART/dmgbuild.log" >&2; exit 1; }
elif [ "$STEP" = "ship" ]; then
  echo "ship: the disk image's window could not be laid out (dmgbuild needs Python 3 and, the first time, a network)" >&2
  exit 1
else
  echo "note: no dmgbuild — a plain disk image, without its window laid out" >&2
  STAGE="build/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format ULMO -quiet "$DMG"
  rm -rf "$STAGE"
fi
rm -rf "$ART"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "packed: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"

[ "$STEP" = "dmg" ] && exit 0

[ -z "$IDENTITY" ] && { echo "can't ship without a Developer ID certificate" >&2; exit 1; }
[ -z "$NOTARY_PROFILE" ] && { echo "can't ship without NOTARY_PROFILE in $BUILD_ENV" >&2; exit 1; }
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "shipped: $DMG"
