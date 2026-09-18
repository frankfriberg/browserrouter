#!/bin/sh
# Build BrowserRouter.app from src/ and register it.
#
# **The bundle id and the path never change**, because the default-browser binding and the
# Automation grant are both attached to them. A rename would mean re-picking the handler
# and re-approving control of every browser.
#
# The Info.plist is written whole rather than patched: PlistBuddy writes these keys
# correctly and then aborts on exit, so a patch-based build fails after succeeding.
set -e
# The checkout, wherever it sits. The *app* path below is the fixed one; the source is
# not, so it is derived rather than written down.
ROOT="$(cd "$(dirname "$0")" && pwd)"
# The install target. Overridable **only** so the packager can stage a copy for a dmg;
# an ordinary build still lands on the one fixed path the browser binding is attached to.
APP="${BROWSERROUTER_APP:-$HOME/Applications/BrowserRouter.app}"
# Staging builds are nobody's handler yet, so they neither register nor restart anything.
STAGED=$([ -n "$BROWSERROUTER_APP" ] && echo 1 || echo "")
# Ad-hoc by default; a Developer ID identity, when there is one, is what makes the dmg
# openable on someone else's Mac without the right-click dance.
SIGN_ID="${BROWSERROUTER_SIGN_ID:--}"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# **The deployment target is the whole of the app's backwards compatibility**, and
# swiftc's default is whatever this Mac happens to be running: a build made here would
# stamp minos 26 and then refuse to launch on anything older, with dyld's message about a
# newer OS and no hint that a rebuild is all it needs. Named explicitly, and kept in step
# with LSMinimumSystemVersion below. 12.0 is the floor the *code* sets, not a preference —
# `NSWorkspace.setDefaultApplication` is Monterey, and without it there is no way to ask
# for the default browser at all.
DEPLOYMENT_TARGET=12.0

# **Sparkle is fetched, not committed.** It is a 3MB signed binary that would otherwise sit
# in the history for ever, and the one thing that matters about it — that this is the build
# Sparkle published and not something that arrived in its place — is a checksum, not a
# copy. Cached, so an ordinary rebuild is offline.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
VENDOR="$ROOT/vendor"
SPARKLE="$VENDOR/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
  mkdir -p "$VENDOR"
  TAR="$VENDOR/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -sL -o "$TAR" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA  $TAR" | shasum -a 256 -c - >/dev/null || {
    echo "Sparkle-$SPARKLE_VERSION.tar.xz is not the archive this build expects" >&2
    rm -f "$TAR"; exit 1; }
  tar -xJf "$TAR" -C "$VENDOR" Sparkle.framework bin
  rm -f "$TAR"
fi

# The version is the tag, and the build number is the number of commits — **monotonic
# without anyone maintaining it**, which is the only property Sparkle needs to decide that
# one build is newer than another.
SHORT_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
[ -n "$SHORT_VERSION" ] || SHORT_VERSION=0.1
BUILD_VERSION="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

swiftc -swift-version 5 -O -target "arm64-apple-macos$DEPLOYMENT_TARGET" \
  -F "$VENDOR" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$ROOT/src/Browsers.swift" "$ROOT/src/Rules.swift" "$ROOT/src/Store.swift" "$ROOT/src/Router.swift" \
  "$ROOT/src/Setup.swift" "$ROOT/src/Updater.swift" "$ROOT/src/UI.swift" "$ROOT/src/main.swift" \
  -o "$APP/Contents/MacOS/BrowserRouter"

# The icon is drawn by src's sibling tool rather than stored as a blob, so a change to it
# is a change to code.
if [ ! -f "$ROOT/icon/AppIcon.icns" ] || [ "$ROOT/icon/MakeIcon.swift" -nt "$ROOT/icon/AppIcon.icns" ]; then
  swiftc -swift-version 5 -O "$ROOT/icon/MakeIcon.swift" -o "$ROOT/icon/makeicon"
  rm -rf "$ROOT/icon/BrowserRouter.iconset"
  "$ROOT/icon/makeicon" "$ROOT/icon/BrowserRouter.iconset" >/dev/null
  iconutil -c icns "$ROOT/icon/BrowserRouter.iconset" -o "$ROOT/icon/AppIcon.icns"
fi
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# **The XPC services are for sandboxed apps, and this one is not.** Shipping them means two
# more bundles to sign, notarize and keep valid, to do a job the framework does in-process
# when there is no sandbox to get around.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>BrowserRouter</string>
  <!-- **The old name, kept on purpose.** This identifier is what the default-browser
       binding and every Automation grant hang off; renaming it to match the app would
       make macOS treat this as a new app and ask for all of them again. -->
  <key>CFBundleIdentifier</key><string>com.frankfriberg.diarouter</string>
  <key>CFBundleName</key><string>BrowserRouter</string>
  <key>CFBundleDisplayName</key><string>BrowserRouter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>SHORTVERSION</string>
  <key>CFBundleVersion</key><string>BUILDVERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>MINOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- Sparkle. The feed is a static file on this repo's Pages branch; the key is what makes
       a download from it trustworthy, and it is checked before anything is unpacked. -->
  <key>SUFeedURL</key><string>https://frankfriberg.github.io/browserrouter/appcast.xml</string>
  <key>SUPublicEDKey</key><string>63CTK+9wYMzAOlQoTunsSsOTRfv/UE4zXzH9/3knHwM=</string>
  <!-- **Answered here rather than asked on first launch.** Sparkle otherwise opens with a
       "check automatically?" prompt, and an agent app has nowhere to show one — it would
       arrive behind whatever the user is looking at, on a launch they did not perform. -->
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <!-- **The only thing that keeps the Dock icon from flashing on every link.** Delivering
       a url promotes the handler to a foreground app, and the promotion lands after the
       handler returns, so demoting from inside the app can only ever undo a blink that has
       already been seen. This is the key LaunchServices itself reads, and it does not cost
       the app its place in the default-browser list. -->
  <key>LSUIElement</key><true/>
  <!-- Required to drive the browsers. Without it the Automation prompt has nothing to say
       and the request is refused rather than asked. **One grant per browser**, asked for
       the first time a link is routed into each. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>BrowserRouter puts a link in the right browser profile, and reuses a tab that already has it.</string>
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
  <!-- **`public.xhtml` is what makes this a browser as far as System Settings is
       concerned.** Its "Default web browser" menu lists the apps that claim the http
       scheme *and* xhtml; declaring http/https and `public.html` alone puts the app in
       LaunchServices' handler tables and nowhere a user can see — measured against the
       menu's own contents, which match that intersection exactly. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# **The one key in the plist that is not a constant**, substituted rather than written in,
# so the heredoc above stays quoted and the plist's minimum cannot drift from the one the
# binary was actually compiled for. Done here because it is an edit to a file that is about
# to be signed, and an edit after signing is a broken signature.
sed -i '' "s|<string>MINOS</string>|<string>$DEPLOYMENT_TARGET</string>|" "$APP/Contents/Info.plist"
sed -i '' "s|<string>SHORTVERSION</string>|<string>$SHORT_VERSION</string>|" "$APP/Contents/Info.plist"
sed -i '' "s|<string>BUILDVERSION</string>|<string>$BUILD_VERSION</string>|" "$APP/Contents/Info.plist"

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
  # **Signed inner-out, one bundle at a time.** `--deep` is not enough for a nested
  # framework that has to be notarized: it re-signs what it finds with the *outer* bundle's
  # options, and Sparkle's helpers are executables in their own right that each need the
  # hardened runtime and a timestamp of their own. Notarization rejects the lot otherwise,
  # and says so about a path inside the framework rather than about the app.
  SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
  for nested in \
    "$SPARKLE_IN_APP/Versions/B/Updater.app" \
    "$SPARKLE_IN_APP/Versions/B/Autoupdate" \
    "$SPARKLE_IN_APP"; do
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$nested"
  done
  # The app last, and **without `--deep`**, so nothing above is re-signed with the app's
  # entitlements. The Apple-events entitlement belongs to the app; an updater that carries
  # it is an updater asking for something it never uses.
  codesign --force --options runtime --timestamp \
    --entitlements "$ENT" -s "$SIGN_ID" "$APP"
  rm -f "$ENT"
  # Read back, because a nested bundle that failed to sign is a notarization rejection
  # twenty minutes later rather than an error here.
  codesign --verify --deep --strict "$APP"
fi
[ -n "$STAGED" ] || "$LS" -f "$APP"

# **Checked by reading it back**, because a bundle that builds and is not offered a single
# link looks identical to one that works until you click something.
for key in CFBundleIdentifier CFBundleURLTypes NSAppleEventsUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || {
    echo "Info.plist is missing $key" >&2; exit 1; }
done
# **The version that decides whether the app launches at all is the binary's**, not the
# plist's: dyld reads one, LaunchServices the other, and they are set in different places.
# Read back rather than trusted, because the flag above has a default — this machine's own
# OS — and losing it produces a build that works everywhere it is tested and nowhere it is
# sent.
MINOS="$(otool -l "$APP/Contents/MacOS/BrowserRouter" | awk '/LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { print $2; exit }')"
[ "$MINOS" = "$DEPLOYMENT_TARGET" ] || {
  echo "binary is built for macOS $MINOS, not $DEPLOYMENT_TARGET" >&2; exit 1; }

LABEL=com.frankfriberg.diarouter
AGENT="gui/$(id -u)/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY="$HOME/Applications/DiaRouter.app"

# **The rename leaves two things behind that both still work**, which is the dangerous
# kind of leftover: a login agent that launches a bundle by path, and that bundle, which
# claims this same identifier and version. LaunchServices picks between same-identifier
# bundles by version and can pick the dead one, which looks from here like a
# default-browser change that fails on a file nobody named. Both are withdrawn while
# there is still a path to name them by.
if [ -z "$STAGED" ] && [ -e "$LEGACY" ]; then
  if [ -f "$PLIST" ] && grep -q "DiaRouter.app" "$PLIST"; then
    sed -i '' "s|$LEGACY|$APP|" "$PLIST"
    launchctl bootout "$AGENT" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    echo "repointed the login agent at $APP"
  fi
  "$LS" -u "$LEGACY" 2>/dev/null || true
  rm -rf "$LEGACY"
  echo "removed the old $LEGACY"
fi

# **A rebuild has to replace the resident process.** Otherwise the old binary keeps
# handling every link and the change looks like it did not take.
if [ -z "$STAGED" ] && launchctl print "$AGENT" >/dev/null 2>&1; then
  osascript -e 'tell application "BrowserRouter" to quit' >/dev/null 2>&1 || true
  sleep 1
  launchctl kickstart -k "$AGENT" >/dev/null 2>&1 || true
  echo "restarted the resident router"
fi

echo "built $APP"
