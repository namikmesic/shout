#!/bin/zsh
# Packages dist/Shout.app as dist/Shout-<version>.dmg (drag Shout to Applications), signed like the app, and
# writes its SHA-256 next to it. Run scripts/build-app.sh first.
# Usage: scripts/make-dmg.sh [--notarize]
#   --notarize  sends the disk image to Apple and staples the ticket, so it opens without a Gatekeeper warning.
#               Needs a "Developer ID Application" signature and APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD
#               (an app-specific password from account.apple.com).
# Environment: SHOUT_DMG_VERSION names the file (default: the app's version), e.g. 1.2.0-beta.1 for a prerelease,
# whose app version can only be 1.2.0.
set -euo pipefail
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    *) echo "usage: scripts/make-dmg.sh [--notarize]" >&2; exit 2 ;;
  esac
done
ROOT="${0:A:h:h}"
APP="$ROOT/dist/Shout.app"
[[ -d "$APP" ]] || { echo "No $APP: run scripts/build-app.sh first" >&2; exit 1; }
VERSION="${SHOUT_DMG_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
NAME="Shout-$VERSION.dmg"
DMG="$ROOT/dist/$NAME"
# The certificate the app is signed with (none when ad-hoc); the disk image gets the same one. awk reads to the end:
# quitting at the first match would make codesign die of SIGPIPE, which pipefail turns into a silent exit.
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !found {print $2; found=1}')"

if (( NOTARIZE )); then
  [[ "$AUTHORITY" == "Developer ID Application"* ]] || {
    echo "Notarization needs a Developer ID Application signature; the app is signed with: ${AUTHORITY:-ad-hoc}" >&2
    exit 1
  }
  for v in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    [[ -n "${(P)v:-}" ]] || { echo "$v is not set" >&2; exit 1; }
  done
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/Shout.app"
ln -s /Applications "$STAGE/image/Applications"

echo "▸ Creating $NAME"
rm -f "$DMG"
# hdiutil sometimes fails with "Resource busy" right after a build; a retry is enough.
for try in 1 2 3; do
  hdiutil create -volname "Shout $VERSION" -srcfolder "$STAGE/image" -fs HFS+ -format UDZO -ov -quiet "$DMG" && break
  (( try < 3 )) || exit 1
  echo "  hdiutil failed, retrying"; sleep 5
done

if [[ -n "$AUTHORITY" ]]; then
  echo "▸ Signing $NAME with: $AUTHORITY"
  TIMESTAMP=--timestamp=none
  [[ "$AUTHORITY" == "Developer ID Application"* ]] && TIMESTAMP=--timestamp
  codesign --force "$TIMESTAMP" --sign "$AUTHORITY" "$DMG"
fi

if (( NOTARIZE )); then
  echo "▸ Notarizing (usually a few minutes)"
  OUT="$STAGE/notary.plist"
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
    --wait --timeout 30m --output-format plist > "$OUT" || true
  STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$OUT" 2>/dev/null || true)"
  ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$OUT" 2>/dev/null || true)"
  if [[ "$STATUS" != Accepted ]]; then
    echo "Notarization failed: ${STATUS:-no answer}" >&2
    cat "$OUT" >&2
    [[ -z "$ID" ]] || xcrun notarytool log "$ID" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" >&2 || true
    exit 1
  fi
  xcrun stapler staple -q "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

(cd "$ROOT/dist" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "✓ $DMG"
