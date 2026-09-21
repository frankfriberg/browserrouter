# Releasing a new version

The version number comes from the git tag and the build number from the commit count
(`build.sh:59`), so **tag first, then package**. Everything else is two scripts.

## 1. Write the release notes

`notes/<version>.html` — a fragment, no `<html>` wrapper. Sparkle renders it in the update
window, so it is read by someone deciding whether to click Install:

- an `<h2>` saying what changed, in words, not a version number;
- a paragraph or two on the one thing that matters;
- a `<ul>` for the rest.

Short. Nobody reads an update window twice.

## 2. Tag

```sh
git commit -m "docs: release notes for 0.3" notes/0.3.html
git push
git tag v0.3 && git push origin v0.3
```

## 3. Build, sign, notarize

```sh
BROWSERROUTER_SIGN_ID="Developer ID Application: Frank Friberg (6855EJ9AC5)" \
BROWSERROUTER_NOTARY_PROFILE=browserrouter \
./package.sh
```

Two notarization round-trips — the app, then the dmg — so a few minutes. It produces
`build/BrowserRouter.dmg`, `build/release/BrowserRouter-<version>.zip`, and a regenerated
`docs/appcast.xml`.

If it stops at `No Keychain password item found`, the stored credentials are gone. Recreate
them and run again:

```sh
xcrun notarytool store-credentials browserrouter \
  --apple-id frank.fri@me.com --team-id 6855EJ9AC5
```

## 4. Publish

```sh
gh release create v0.3 build/release/BrowserRouter-0.3.zip build/BrowserRouter.dmg \
  --title "0.3" --notes-file notes/0.3.html
git commit -m "release: v0.3" docs/appcast.xml && git push
```

The zip filename is load-bearing: the appcast enclosure url is built from it. Committing
`docs/appcast.xml` is what actually ships the update — until then the release exists and
nobody is offered it.

## 5. Check

```sh
spctl -a -vv -t install build/BrowserRouter.dmg   # expect: Notarized Developer ID
```

## Notes

- **The dmg is for installing, the zip is for updating.** Sparkle unpacks a zip in place;
  mounting a dmg would put a second bundle with this identifier into LaunchServices.
- **`build/` is not in git**, so `package.sh` seeds the old feed from `docs/appcast.xml`
  before regenerating it. Don't delete that file — the older entries carry their own
  `minimumSystemVersion` and are what an out-of-date Mac is offered.
- A build made without a tag falls back to version 0.1.
