#!/bin/bash
#
# Builds and ships the Swagatar fork of Talkify (ADR 9000). Never touches
# upstream's identity: bundle ID, signing team, Sparkle key and feed are all
# swapped in here, at build time, from release/swagatar.xcconfig and the
# environment, so the committed sources stay byte-identical to what upstream
# reviews.
#
#   release/swagatar-release.sh build              # Release build, signed, Sparkle inert
#   release/swagatar-release.sh install            # build + copy to /Applications
#   release/swagatar-release.sh publish <version>  # notarize, DMG, GitHub release + appcast
#
# build/install need only the Developer ID certificate and work today.
# publish additionally needs, and refuses to run without:
#   SWAGATAR_SUPUBLIC_KEY  public half of the fork's own Sparkle EdDSA key
#                          (scripts/setup-sparkle-keys.sh prints it; the private
#                          half stays in the login Keychain, never in a repo)
#   NOTARY_PROFILE         notarytool keychain profile name
# and it stops for the licensing blockers ADR 9000 inherits: the Pop sound set
# (CC-BY-NC) and the Siri-orb artwork must be replaced or dropped before any
# public release. Set SWAGATAR_ACKNOWLEDGE_ASSETS=1 only once that is resolved.

set -euo pipefail

MODE="${1:-}"
VERSION="${2:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_ID="co.swagatar.Talkify"
IDENTITY="Developer ID Application"
FEED_URL="https://github.com/Swagatar-LLC/Talkify/releases/latest/download/appcast.xml"
DERIVED="release/build"
APP="$DERIVED/Build/Products/Release/Talkify.app"
PLIST="$APP/Contents/Info.plist"

fail() { echo "error: $*" >&2; exit 1; }

build() {
  xcodebuild -project Talkify.xcodeproj -scheme Talkify -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    -xcconfig release/swagatar.xcconfig build

  # Point Sparkle at the fork's channel, or disarm it entirely. A build that
  # kept upstream's SUPublicEDKey and feed would look for updates it must
  # never accept, and accepting one would hand the fork to upstream's key.
  if [[ -n "${SWAGATAR_SUPUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SWAGATAR_SUPUBLIC_KEY" "$PLIST"
  else
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PLIST"
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST"
    /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST"
  fi

  # The plist edit broke the app seal; re-sign the outer bundle only, keeping
  # the entitlements the build applied. Nested Sparkle signatures are intact.
  codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --strict --deep "$APP"

  # Release-time identity verification (upstream issue #56, applied here from
  # day one): the artifact must carry the fork's identity, not upstream's.
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "$BUNDLE_ID" ]] \
    || fail "built app does not carry $BUNDLE_ID"
  if [[ -n "${SWAGATAR_SUPUBLIC_KEY:-}" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" == "$SWAGATAR_SUPUBLIC_KEY" ]] \
      || fail "built app does not carry the Swagatar Sparkle key"
  fi
  ! /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" 2>/dev/null \
    | grep -q tornikegomareli || fail "built app still points at upstream's feed"

  echo "built and signed: $APP"
}

install_app() {
  build
  if pgrep -x Talkify >/dev/null; then
    echo "Talkify is running; quit it from the status menu first" >&2
    exit 1
  fi
  rm -rf /Applications/Talkify.app
  ditto "$APP" /Applications/Talkify.app
  echo "installed /Applications/Talkify.app ($BUNDLE_ID)"
}

publish() {
  [[ -n "$VERSION" ]] || fail "usage: release/swagatar-release.sh publish <version>"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be semver, got '$VERSION'"
  [[ -n "${SWAGATAR_SUPUBLIC_KEY:-}" ]] || fail "SWAGATAR_SUPUBLIC_KEY is not set; run scripts/setup-sparkle-keys.sh"
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "NOTARY_PROFILE is not set; run: xcrun notarytool store-credentials"
  [[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
  [[ "${SWAGATAR_ACKNOWLEDGE_ASSETS:-}" == "1" ]] \
    || fail "the Pop sound set and Siri-orb artwork are not licensed for release (see LICENSE-SOUNDS.txt, LICENSE-ARTWORK.txt and ADR 9000); resolve them, then set SWAGATAR_ACKNOWLEDGE_ASSETS=1"

  SIGN_UPDATE="$(find "$DERIVED/SourcePackages/artifacts" "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*parkle*/bin/sign_update' -print -quit 2>/dev/null)"
  [[ -n "$SIGN_UPDATE" ]] || fail "Sparkle's sign_update tool not found; build once so SPM fetches the Sparkle artifact"

  build

  local staging dmg
  staging="$(mktemp -d)"
  ditto "$APP" "$staging/Talkify.app"

  ditto -c -k --keepParent "$staging/Talkify.app" "$staging/Talkify.zip"
  xcrun notarytool submit "$staging/Talkify.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$staging/Talkify.app"

  dmg="$staging/Talkify-Swagatar-v$VERSION.dmg"
  hdiutil create -volname Talkify -srcfolder "$staging/Talkify.app" -ov -format UDZO "$dmg"

  local sig length
  sig="$("$SIGN_UPDATE" "$dmg" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  [[ -n "$sig" ]] || fail "sign_update produced no signature; is the private key in the login Keychain?"
  length="$(stat -f %z "$dmg")"

  cat > "$staging/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Talkify (Swagatar fork)</title>
    <item>
      <title>$VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/Swagatar-LLC/Talkify/releases/download/swagatar-v$VERSION/Talkify-Swagatar-v$VERSION.dmg"
        sparkle:edSignature="$sig" length="$length" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

  # Release notes accumulate in fork-unreleased.md as changes land, so a
  # release ships the changelog that was written next to the work instead of
  # one reconstructed from git log at publish time.
  local notes_file="docs/release-notes/fork-unreleased.md"
  local disclaimer notes
  disclaimer="Swagatar fork build of Talkify at $(git rev-parse --short HEAD). Not an upstream release."
  if [[ -s "$notes_file" ]]; then
    notes="$(cat "$notes_file")"$'\n\n'"$disclaimer"
  else
    notes="$disclaimer"
  fi

  gh release create "swagatar-v$VERSION" --repo Swagatar-LLC/Talkify \
    --title "Swagatar fork v$VERSION" \
    --notes "$notes" \
    "$dmg" "$staging/appcast.xml"

  if [[ -s "$notes_file" ]]; then
    mv "$notes_file" "docs/release-notes/fork-$VERSION.md"
    echo "notes archived as docs/release-notes/fork-$VERSION.md; commit that rename"
  fi
  echo "published swagatar-v$VERSION; feed: $FEED_URL"
}

case "$MODE" in
  build) build ;;
  install) install_app ;;
  publish) publish ;;
  *) fail "usage: release/swagatar-release.sh build|install|publish [version]" ;;
esac
