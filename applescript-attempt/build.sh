#!/bin/sh
# Compile DiaRouter.applescript into the handler app and register it.
#
# **An AppleScript applet, not a Swift app.** A Swift build of this existed and is kept in
# swift-attempt/ — it worked, and the cost was that a link waited on a cold app launch
# before anything opened. The applet is what a link can afford.
#
# **osacompile writes a fresh bundle**, so every Info.plist key it does not know about has
# to be re-added here — the url types are what make the app a browser LaunchServices will
# hand a link to, and the document types are what a real browser declares beside them.
# Losing either silently turns the app back into a script nobody calls.
#
# The bundle id and the path never change, because the default-browser binding and the
# Automation grant are both attached to them.
set -e
ROOT="$HOME/.dia-router"
APP="$HOME/Applications/DiaRouter.app"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$APP"
osacompile -o "$APP" "$ROOT/DiaRouter.applescript"

P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
 -c "Add :CFBundleIdentifier string com.frankfriberg.diarouter" \
 -c "Add :CFBundleURLTypes array" \
 -c "Add :CFBundleURLTypes:0 dict" \
 -c "Add :CFBundleURLTypes:0:CFBundleURLName string Web site URL" \
 -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer" \
 -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
 -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string http" \
 -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string https" \
 -c "Add :CFBundleDocumentTypes array" \
 -c "Add :CFBundleDocumentTypes:0 dict" \
 -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string HTML document" \
 -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" \
 -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Alternate" \
 -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
 -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.html" \
 "$P" >/dev/null 2>&1 || true

# The icon the Swift attempt left behind, which is the half of it worth keeping. Written
# over the applet's own default rather than added under a new name, so nothing depends on
# CFBundleIconFile changing.
if [ -f "$ROOT/icon/AppIcon.icns" ]; then
  cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/applet.icns"
fi

# **PlistBuddy is checked by reading the result back, not by its exit status** — it writes
# these keys correctly and then aborts on exit, so trusting the code aborts the build after
# a perfectly good patch.
for key in CFBundleIdentifier CFBundleURLTypes:0:CFBundleURLSchemes:0 CFBundleDocumentTypes:0:LSItemContentTypes:0; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$P" >/dev/null 2>&1 || {
      echo "missing $key — the app would not be offered a single url" >&2
      exit 1
  }
done

codesign --force --deep -s - "$APP" 2>/dev/null
"$LS" -f "$APP"
echo "built $APP"
