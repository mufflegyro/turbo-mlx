#!/bin/zsh
# A development disk image of the app, for trying a change on the Macs it is meant for: Release
# build signed with the keychain's "Apple Development" certificate (not notarized), packaged as
# build/release-apple-development/Turbo-MLX-<version>-<build>-apple-development.dmg next to the
# earlier ones.
#
# Usage: scripts/dev-release.sh                    -> the next build number, written to the project
#        scripts/dev-release.sh --build 41         -> that build number, the project's unchanged
#        scripts/dev-release.sh --copy-to-desktop  -> also a copy on the Desktop
#        CODE_SIGN_IDENTITY="Apple Development: … (XXXXXXXXXX)" scripts/dev-release.sh
#
# The build number (CURRENT_PROJECT_VERSION) grows on every run and is written to the project, so
# the later DMGs name a newer build than everything built before. Older DMGs are kept. For the
# published release use scripts/release.sh: a Developer ID signature, notarization, and the update
# feed.
set -euo pipefail

cd "${0:A:h}/.."

MARKETING=$(sed -nE 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/p' TurboMLX.xcodeproj/project.pbxproj | head -1)
CURRENT=$(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' TurboMLX.xcodeproj/project.pbxproj | head -1)
if [[ -z "$MARKETING" || -z "$CURRENT" ]]; then
  print -u2 "Could not read MARKETING_VERSION and CURRENT_PROJECT_VERSION from TurboMLX.xcodeproj"
  exit 1
fi

OUT="build/release-apple-development"
DERIVED="build/dev-release"
BUILD=""
COPY_TO_DESKTOP=0

while (( $# )); do
  case "$1" in
    --build) BUILD="${2:-}"; shift 2 ;;
    --copy-to-desktop) COPY_TO_DESKTOP=1; shift ;;
    -h|--help) sed -nE '2,14s/^# ?//p' "$0"; exit 0 ;;
    *) print -u2 "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

step() { print -P "%F{cyan}==>%f $*" }

# The certificate and its team. Signing.local.xcconfig, the git-ignored file a local build signs
# with, names both; the keychain's first Apple Development identity and its certificate do when
# there is no such file.
setting() {
  [[ -f Signing.local.xcconfig ]] || return 0
  sed -nE "s/^$1[[:space:]]*=[[:space:]]*(.+)$/\1/p" Signing.local.xcconfig | tail -1
}
IDENTITY="${CODE_SIGN_IDENTITY:-$(setting CODE_SIGN_IDENTITY)}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development: [^"]+)"$/\1/p' | head -1)
fi
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || {
  print -u2 "No \"Apple Development\" certificate to sign with. Add it, with its team, to Signing.local.xcconfig:"
  print -u2 "  CODE_SIGN_IDENTITY = Apple Development: name@example.com (XXXXXXXXXX)"
  print -u2 "  DEVELOPMENT_TEAM = ABCDE12345"
  exit 1
}
TEAM_ID="${DEVELOPMENT_TEAM:-$(setting DEVELOPMENT_TEAM)}"
if [[ -z "$TEAM_ID" ]]; then
  # The certificate's own team: the OU of the one whose name the identity names.
  TEAM_ID=$(security find-certificate -c "${IDENTITY% (*}" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -nE 's/.*OU[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' | head -1)
fi
[[ -n "$TEAM_ID" ]] || { print -u2 "The team of \"$IDENTITY\" could not be read: set DEVELOPMENT_TEAM."; exit 1 }

# The newest build already on disk, so a --build or a bumped number never reuses one.
latest=0
for dmg in "$OUT"/Turbo-MLX-*-*-apple-development.dmg(N); do
  number="${${dmg:t}%-apple-development.dmg}"
  number="${number##*-}"
  if (( number > latest )); then latest=$number; fi
done

if [[ -z "$BUILD" ]]; then
  BUILD=$(( CURRENT > latest ? CURRENT : latest ))
  BUILD=$(( BUILD + 1 ))
  step "Build $BUILD: the project's CURRENT_PROJECT_VERSION $CURRENT becomes $BUILD"
  sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" \
    TurboMLX.xcodeproj/project.pbxproj
else
  [[ "$BUILD" == <-> ]] || { print -u2 "--build wants a number, not \"$BUILD\""; exit 1 }
  step "Build $BUILD, as asked; the project keeps CURRENT_PROJECT_VERSION $CURRENT"
fi

APP="$DERIVED/Build/Products/Release/Turbo MLX.app"
DMG="$OUT/Turbo-MLX-$MARKETING-$BUILD-apple-development.dmg"

step "Building (Release, $IDENTITY)"
xcodebuild -quiet -project TurboMLX.xcodeproj -scheme TurboMLX -configuration Release \
  -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

step "Verifying the app"
codesign --verify --deep --strict --verbose=2 "$APP"
[[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")" == "$BUILD" ]] || {
  print -u2 "The app is not build $BUILD: the build did not pick up the project's version"
  exit 1
}
# The app generates nothing without its engine, which must inherit the app's sandbox to start.
[[ -x "$APP/Contents/MacOS/turbo-engine" ]] || {
  print -u2 "turbo-engine is missing from the app: the Embed turbo-engine phase failed"
  exit 1
}
codesign -d --entitlements - "$APP/Contents/MacOS/turbo-engine" 2>/dev/null \
  | grep -q "com.apple.security.inherit" || {
  print -u2 "turbo-engine is not signed with Engine/turbo-engine.entitlements: the sandboxed app could not start it"
  exit 1
}

step "Disk image"
mkdir -p "$OUT"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/turbo-mlx-dmg.XXXXXX")
MNT="$STAGE/mnt"
cleanup() {
  # Whatever went wrong, the image is unmounted and only the staging folder made above goes.
  if [[ -n "$MNT" && -d "$MNT" ]]; then hdiutil detach "$MNT" -quiet 2>/dev/null || true; fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
  return 0
}
trap cleanup EXIT
ditto "$APP" "$STAGE/Turbo MLX.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Turbo MLX" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

step "Verifying the disk image"
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
codesign --verify --deep --strict "$MNT/Turbo MLX.app"
[[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$MNT/Turbo MLX.app/Contents/Info.plist")" == "$BUILD" ]] || {
  print -u2 "The app inside the disk image is not build $BUILD"
  hdiutil detach "$MNT" -quiet
  exit 1
}
hdiutil detach "$MNT" -quiet

if (( COPY_TO_DESKTOP )); then
  step "Copying to the Desktop"
  cp "$DMG" "$HOME/Desktop/"
fi

print -P "%F{green}==>%f Done: $DMG"
