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
# The checkout, wherever it sits. The *app* path below is the fixed one; the source is
# not, so it is derived rather than written down.
ROOT="$(cd "$(dirname "$0")" && pwd)"
# The install target. Overridable **only** so the packager can stage a copy for a dmg;
# an ordinary build still lands on the one fixed path the browser binding is attached to.
APP="${DIAROUTER_APP:-$HOME/Applications/DiaRouter.app}"
# Staging builds are nobody's handler yet, so they neither register nor restart anything.
STAGED=$([ -n "$DIAROUTER_APP" ] && echo 1 || echo "")
# Ad-hoc by default; a Developer ID identity, when there is one, is what makes the dmg
# openable on someone else's Mac without the right-click dance.
SIGN_ID="${DIAROUTER_SIGN_ID:--}"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -O \
  "$ROOT/src/Rules.swift" "$ROOT/src/Store.swift" "$ROOT/src/Router.swift" \
  "$ROOT/src/Setup.swift" "$ROOT/src/UI.swift" "$ROOT/src/main.swift" \
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
  <!-- **The only thing that keeps the Dock icon from flashing on every link.** Delivering
       a url promotes the handler to a foreground app, and the promotion lands after the
       handler returns, so demoting from inside the app can only ever undo a blink that has
       already been seen. This is the key LaunchServices itself reads, and it does not cost
       the app its place in the default-browser list. -->
  <key>LSUIElement</key><true/>
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

# The hardened runtime and a secure timestamp are what notarization requires, and both
# are meaningless for an ad-hoc signature, so they go on only with a real identity.
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep -s - "$APP"
else
  # **The hardened runtime refuses Apple events unless the app asks for them**, and a
  # refusal here is silent at build time and fatal at the first link: the send fails
  # outright rather than raising the Automation prompt. The usage string in Info.plist
  # is what the prompt *says*; this is what makes there be a prompt at all.
  ENT="$(mktemp -t diarouter).plist"
  cat > "$ENT" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENTS
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENT" -s "$SIGN_ID" "$APP"
  rm -f "$ENT"
fi
[ -n "$STAGED" ] || "$LS" -f "$APP"

# **Checked by reading it back**, because a bundle that builds and is not offered a single
# link looks identical to one that works until you click something.
for key in CFBundleIdentifier CFBundleURLTypes NSAppleEventsUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
    echo "Info.plist is missing $key" >&2; exit 1; }
done
# **A rebuild has to replace the resident process.** Otherwise the old binary keeps
# handling every link and the change looks like it did not take.
AGENT="gui/$(id -u)/com.frankfriberg.diarouter"
if [ -z "$STAGED" ] && launchctl print "$AGENT" >/dev/null 2>&1; then
  osascript -e 'tell application "DiaRouter" to quit' >/dev/null 2>&1 || true
  sleep 1
  launchctl kickstart -k "$AGENT" >/dev/null 2>&1 || true
  echo "restarted the resident router"
fi

echo "built $APP"
