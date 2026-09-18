#!/bin/sh
# Keep BrowserRouter resident, so a link never waits for a cold start.
#
# The app path is **found rather than written down**: this runs on someone else's Mac,
# where the bundle is wherever they dragged it.
set -e
APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.frankfriberg.diarouter'" | head -1)"
[ -n "$APP" ] || APP=$(ls -d /Applications/BrowserRouter.app "$HOME/Applications/BrowserRouter.app" 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "BrowserRouter.app not found — drag it to Applications first" >&2; exit 1; }

LABEL=com.frankfriberg.diarouter
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <!-- Launched through \`open\` rather than by running the binary directly, so the process
       is the app bundle as LaunchServices knows it — which is what lets it receive the
       url events and keeps its Automation grant. \`--resident\` is what stops it showing
       the rules window at login. -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$APP</string>
    <string>--args</string>
    <string>--resident</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- No KeepAlive: \`open\` exits as soon as it has launched the app, so launchd would
       relaunch it forever. If the app ever does die, the next link cold-starts it once. -->
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "BrowserRouter will start at login, from $APP"
