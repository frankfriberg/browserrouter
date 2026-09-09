#!/bin/sh
# Build DiaRouter.app from src/ and register it.
#
# **The bundle id and the path never change**, because the default-browser binding and the
# Automation grant are both attached to them. A rename would mean re-picking the handler
# and re-approving control of Dia.
#
# The Info.plist is written whole rather than patched: PlistBuddy writes these keys
# correctly and then aborts on exit, so a patch-based build fails after succeeding.
set -e
ROOT="$HOME/.dia-router"
APP="$HOME/Applications/DiaRouter.app"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -O \
  "$ROOT/src/Rules.swift" "$ROOT/src/Store.swift" "$ROOT/src/Router.swift" \
  "$ROOT/src/UI.swift" "$ROOT/src/main.swift" \
  -o "$APP/Contents/MacOS/DiaRouter"

# The icon is drawn by src's sibling tool rather than stored as a blob, so a change to it
# is a change to code.
if [ ! -f "$ROOT/icon/AppIcon.icns" ] || [ "$ROOT/icon/MakeIcon.swift" -nt "$ROOT/icon/AppIcon.icns" ]; then
  swiftc -swift-version 5 -O "$ROOT/icon/MakeIcon.swift" -o "$ROOT/icon/makeicon"
  rm -rf "$ROOT/icon/DiaRouter.iconset"
  "$ROOT/icon/makeicon" "$ROOT/icon/DiaRouter.iconset" >/dev/null
  iconutil -c icns "$ROOT/icon/DiaRouter.iconset" -o "$ROOT/icon/AppIcon.icns"
fi
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DiaRouter</string>
  <key>CFBundleIdentifier</key><string>com.frankfriberg.diarouter</string>
  <key>CFBundleName</key><string>DiaRouter</string>
  <key>CFBundleDisplayName</key><string>DiaRouter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- Required to drive Dia. Without it the Automation prompt has nothing to say and the
       request is refused rather than asked. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>DiaRouter puts a link in the right Dia profile, and reuses a tab that already has it.</string>
  <!-- What makes LaunchServices willing to hand this app a link. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <!-- What a real browser declares beside the schemes. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.html</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" 2>/dev/null
"$LS" -f "$APP"

# **Checked by reading it back**, because a bundle that builds and is not offered a single
# link looks identical to one that works until you click something.
for key in CFBundleIdentifier CFBundleURLTypes NSAppleEventsUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
    echo "Info.plist is missing $key" >&2; exit 1; }
done
# **A rebuild has to replace the resident process.** Otherwise the old binary keeps
# handling every link and the change looks like it did not take.
AGENT="gui/$(id -u)/com.frankfriberg.diarouter"
if launchctl print "$AGENT" >/dev/null 2>&1; then
  osascript -e 'tell application "DiaRouter" to quit' >/dev/null 2>&1 || true
  sleep 1
  launchctl kickstart -k "$AGENT" >/dev/null 2>&1 || true
  echo "restarted the resident router"
fi

echo "built $APP"
