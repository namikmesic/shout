#!/bin/zsh
# Builds Shout.app (release), embeds the ggml frameworks and code-signs everything.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
#
# Environment (all optional):
#   SHOUT_SIGN_IDENTITY  signing identity; default: the first "Developer ID Application", else "Apple Development",
#                         else ad-hoc ("-")
#   SHOUT_VERSION        version shown in Settings (CFBundleShortVersionString), e.g. 1.2.0; default: Info.plist's
#   SHOUT_BUILD          build number (CFBundleVersion); default: Info.plist's
set -euo pipefail
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "usage: scripts/build-app.sh [--install]" >&2; exit 2 ;;
  esac
done
ROOT="${0:A:h:h}"
cd "$ROOT"
APP="$ROOT/dist/Shout.app"
# `|| true`: under pipefail a failing `security` would abort here instead of reaching the ad-hoc fallback.
# Developer ID first: it's the one Apple notarizes, so downloads open without a warning.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
FOUND="$(print -r -- "$IDENTITIES" | awk -F'"' '/Developer ID Application/ && !f {print $2; f=1}')"
[[ -n "$FOUND" ]] || FOUND="$(print -r -- "$IDENTITIES" | awk -F'"' '/Apple Development/ && !f {print $2; f=1}')"
IDENTITY="${SHOUT_SIGN_IDENTITY:-$FOUND}"
IDENTITY="${IDENTITY:--}"   # fall back to ad-hoc signing
# Notarization needs a secure timestamp; other signatures skip it (it needs the network and an Apple certificate).
TIMESTAMP=--timestamp=none
[[ "$IDENTITY" == *"Developer ID Application"* ]] && TIMESTAMP=--timestamp
# The hardened runtime only loads frameworks signed by the same team, and an ad-hoc signature has no team, so an
# ad-hoc app with it can't start. It's only required for notarization, which needs a certificate anyway.
RUNTIME=(--options runtime)
[[ "$IDENTITY" != "-" ]] || RUNTIME=()

echo "▸ Building release binary"
swift build -c release --product Shout

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Shout" "$APP/Contents/MacOS/Shout"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -z "${SHOUT_VERSION:-}" ]] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHOUT_VERSION" "$APP/Contents/Info.plist"
[[ -z "${SHOUT_BUILD:-}" ]] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SHOUT_BUILD" "$APP/Contents/Info.plist"
for fw in whisper llama; do
  ditto "$ROOT/Vendor/$fw.xcframework/macos-arm64_x86_64/$fw.framework" "$APP/Contents/Frameworks/$fw.framework"
done

# Re-render when the icon script changes, not only when the icon is missing.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "▸ Rendering icon"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  swift "$ROOT/scripts/make-icon.swift" "$TMP/icon_1024.png" >/dev/null
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Make sure the executable finds the embedded frameworks. grep reads all of otool's output (no -q), so
# otool can't die of SIGPIPE and make the pipeline fail under pipefail when the rpath is already there.
if ! otool -l "$APP/Contents/MacOS/Shout" | grep -F "@executable_path/../Frameworks" >/dev/null; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Shout"
fi

echo "▸ Signing with: $IDENTITY"
for fw in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force "${RUNTIME[@]}" "$TIMESTAMP" --sign "$IDENTITY" "$fw"
done
codesign --force "${RUNTIME[@]}" "$TIMESTAMP" --entitlements "$ROOT/Resources/Shout.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
# Starts the signed app far enough to load its frameworks, then quits. A separate assignment so a failure stops here.
LAUNCHED="$("$APP/Contents/MacOS/Shout" --version)"
echo "▸ Launch check: $LAUNCHED"
echo "✓ Built $APP"

if (( INSTALL )); then
  echo "▸ Installing to /Applications"
  # Copy next to the installed app first, so a failed copy leaves the current install in place.
  STAGED=/Applications/.Shout.app.installing
  rm -rf "$STAGED"
  ditto "$APP" "$STAGED"
  pkill -x Shout 2>/dev/null || true
  rm -rf /Applications/Shout.app
  mv "$STAGED" /Applications/Shout.app
  echo "✓ Installed /Applications/Shout.app"
fi
