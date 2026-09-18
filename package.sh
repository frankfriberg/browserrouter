#!/bin/sh
# Build a BrowserRouter.dmg someone else can open.
#
# The dmg is the *only* artifact that leaves this machine, so everything the receiver
# needs is inside it. **That is now the app and a drop target, and nothing else**: the app
# asks for the default-browser and start-at-login steps itself on first open, and a readme
# that also describes them is a second set of instructions to keep in step with the first.
#
# Signing: a sharable dmg is a *notarized* one, so set both BROWSERROUTER_SIGN_ID (a
# "Developer ID Application: ..." identity) and BROWSERROUTER_NOTARY_PROFILE. The README
# describes that dmg and no other — a build missing either one still produces a file, but
# it is one Gatekeeper stops, and it says so on the way out rather than in the README.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
STAGE="$OUT/dmg"
DMG="$OUT/BrowserRouter.dmg"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

BROWSERROUTER_APP="$STAGE/BrowserRouter.app" sh "$ROOT/build.sh"

# The drop target, so installing is one drag rather than a sentence of instructions.
ln -s /Applications "$STAGE/Applications"

# The steps that are not drag-and-drop are **asked for by the app, not written down here**.
# Both need something only the running app knows — the confirmation macOS insists on showing
# for a default-browser change, and the path the bundle was actually dragged to — so the
# readme says where they will be asked rather than how to do them by hand.
cat > "$STAGE/README.txt" <<'TXT'
BrowserRouter — sends each link to the right browser, and the right profile inside it.
Needs an Apple-silicon Mac and macOS 12 Monterey or later, plus at least one of the
browsers it routes to: Dia, Arc, Chrome, Brave, Edge, Vivaldi, Safari, Firefox or Zen.

1. Drag BrowserRouter.app to Applications.
2. Open it once. It offers the two things it cannot do for itself: becoming your default
   browser, so links arrive here at all, and starting at login, so the first link of the
   day does not wait for a cold start. Both are one click, and either can be left for
   later — the Setup link in the window brings the panel back.
3. The window behind that panel is where the rules live: one per line, a host or a url
   prefix on the left, a browser and one of its profiles on the right. The most
   specific rule wins, and a row under them says where everything else goes.
   Under them is a row of checkboxes for sites with their own desktop app — Linear,
   Figma, Notion, Slack, Teams, Asana, Discord, Zoom, Spotify. Ticked, those links go straight to
   the app and no browser tab is ever opened.
4. The first link routed into a browser asks for permission to control it — once per
   browser. Allow it; a refusal is remembered, and undoing it means System Settings →
   Privacy & Security → Automation.

   Safari is the one exception to profiles: it has them, and exposes them to nothing,
   so links go to whichever Safari profile is in front.
TXT

# **The volume icon has to go on while the image is writable**, so the dmg is built
# read-write, decorated, and only then compressed. It is the icon that survives being
# mailed, because it lives inside the image rather than beside it.
RW="$OUT/rw.dmg"
rm -f "$RW"
hdiutil create -quiet -volname BrowserRouter -srcfolder "$STAGE" -ov -format UDRW "$RW"
MNT="$(hdiutil attach -nobrowse -noverify "$RW" | grep /Volumes/ | sed 's/.*\(\/Volumes\/.*\)/\1/')"
cp "$ROOT/icon/AppIcon.icns" "$MNT/.VolumeIcon.icns"
# The icns alone does nothing; the custom-icon bit on the volume is what Finder reads.
SetFile -a C "$MNT"
# **Mounting the image registers the app inside it**, and that record outlives the volume:
# LaunchServices then holds two bundles with this identifier and the same version, one of
# them on a path that no longer exists. It picks between them by version, so the dead one
# can win — which looks, from the app, like a default-browser change that fails on a file
# nobody named. Withdrawn here, while there is still a path to name.
"$LS" -u "$MNT/BrowserRouter.app" 2>/dev/null || true
hdiutil detach "$MNT" -quiet
hdiutil convert -quiet "$RW" -format UDZO -o "$DMG"
rm -f "$RW"

if [ "${BROWSERROUTER_SIGN_ID:--}" != "-" ]; then
  codesign --force -s "$BROWSERROUTER_SIGN_ID" "$DMG"
  # **Notarization is what removes the right-click**, and it is the step that needs
  # credentials rather than a certificate, so it is asked for by name instead of guessed.
  if [ -n "$BROWSERROUTER_NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$BROWSERROUTER_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  else
    echo "signed but not notarized: set BROWSERROUTER_NOTARY_PROFILE to a stored notarytool profile" >&2
  fi
else
  # **Said here rather than in the README**, because it is the builder who can fix it and
  # the receiver who cannot. An ad-hoc dmg is for testing on this machine; anything sent
  # anywhere needs both variables.
  echo "ad-hoc signed: Gatekeeper will refuse this on any other Mac — set BROWSERROUTER_SIGN_ID and BROWSERROUTER_NOTARY_PROFILE to share it" >&2
fi

# The icon on the .dmg *file*, which is a different thing from the volume icon above:
# it lives in an extended attribute, so Finder shows it here and most transfers strip it.
# Set last, because stapling rewrites the file.
SETICON="$(mktemp -t seticon).swift"
cat > "$SETICON" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[2]),
      NSWorkspace.shared.setIcon(img, forFile: a[1]) else {
  FileHandle.standardError.write("could not set the dmg's own icon\n".data(using: .utf8)!)
  exit(1)
}
SWIFT
swift "$SETICON" "$DMG" "$ROOT/icon/AppIcon.icns"
rm -f "$SETICON"

# **The staged copy registers itself**, without help from build.sh, simply by existing
# somewhere LaunchServices scans. It is the same identifier and version as the installed
# app, so it is left withdrawn rather than competing with it.
"$LS" -u "$STAGE/BrowserRouter.app" 2>/dev/null || true

echo "built $DMG"
