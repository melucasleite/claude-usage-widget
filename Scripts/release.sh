#!/usr/bin/env bash
#
# Cut a distributable release: sign → notarize → staple → zip → GitHub Release.
#
#   ./Scripts/release.sh 1.0.0
#   ./Scripts/release.sh 1.0.0 --app path/to/ClaudeUsageWidget.app   # reuse a build
#   ./Scripts/release.sh 1.0.0 --no-publish                          # package only
#   ./Scripts/release.sh 1.0.0 --draft                               # draft release
#   ./Scripts/release.sh 1.0.0 --no-commit                           # bump but don't commit
#
# Notarization needs credentials stored once, which is yours to do — it wants
# an app-specific password from appleid.apple.com:
#
#   xcrun notarytool store-credentials "ClaudeUsageWidget" \
#     --apple-id you@example.com --team-id YOURTEAMID
#
# Override the profile name with NOTARY_PROFILE. An app that already carries a
# stapled ticket is detected and not re-submitted.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeUsageWidget"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClaudeUsageWidget}"

VERSION=""
APP_OVERRIDE=""
PUBLISH=1
DRAFT=0
SKIP_NOTARIZE=0
COMMIT_BUMP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_OVERRIDE="$2"; shift 2 ;;
    --no-publish) PUBLISH=0; shift ;;
    --draft) DRAFT=1; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --no-commit) COMMIT_BUMP=0; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "usage: ./Scripts/release.sh <version> [--app PATH] [--no-publish] [--draft]" >&2
  exit 2
fi
TAG="v${VERSION}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Locate the Developer ID certificate.
#
# Note this is NOT "Apple Distribution" — that is the App Store certificate,
# and Gatekeeper does not accept it for direct distribution. It is also not
# "Apple Development", which is blocked outright on other people's machines.
# ---------------------------------------------------------------------------
step "Signing identity"
IDENTITY="${CODESIGN_IDENTITY:-$(
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | sed -n 's/.*"\(.*\)"/\1/p' | head -1
)}"

if [[ -z "$IDENTITY" ]]; then
  fail "no 'Developer ID Application' certificate found.

  Create one in Xcode > Settings > Accounts > Manage Certificates > +.
  The menu entry only appears for the team's Account Holder.
  'Apple Distribution' is the App Store certificate and will not work here."
fi
echo "    $IDENTITY"

# ---------------------------------------------------------------------------
# 2. Stamp the version into the sources.
#
# This used to be missing, and the omission was invisible: the tag, the
# filenames and the release page all said one version while the bundle's
# Info.plist still said whatever was last committed. v1.0.6 shipped reporting
# 1.0.2 in its own About box. A mislabelled binary is worse than an unlabelled
# one — it makes every future bug report point at the wrong code.
#
# Skipped when adopting a pre-built bundle with --app, since its version is
# already baked in and gets verified below either way.
# ---------------------------------------------------------------------------
if [[ -z "$APP_OVERRIDE" ]]; then
  step "Stamping version $VERSION"

  plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
  sed -i '' "s/^    MARKETING_VERSION: .*/    MARKETING_VERSION: \"$VERSION\"/" project.yml

  # Monotonic build number, which the App Store cares about and humans do not.
  CURRENT_BUILD="$(sed -n 's/^    CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)"
  NEXT_BUILD=$(( ${CURRENT_BUILD:-0} + 1 ))
  sed -i '' "s/^    CURRENT_PROJECT_VERSION: .*/    CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" project.yml
  echo "    marketing $VERSION · build $NEXT_BUILD"

  if [[ "$COMMIT_BUMP" == "1" ]] && git diff --quiet --exit-code -- project.yml Resources/Info.plist; then
    echo "    (already at this version, nothing to commit)"
  elif [[ "$COMMIT_BUMP" == "1" ]]; then
    git add project.yml Resources/Info.plist
    git commit -q -m "Release $VERSION" -- project.yml Resources/Info.plist \
      && echo "    committed the bump" \
      || echo "    (could not commit; continuing)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Build, or adopt an existing app bundle.
# ---------------------------------------------------------------------------
if [[ -n "$APP_OVERRIDE" ]]; then
  step "Using existing bundle"
  APP="$APP_OVERRIDE"
  [[ -d "$APP" ]] || fail "no app bundle at $APP"
  echo "    $APP"
else
  step "Building"
  CODESIGN_IDENTITY="$IDENTITY" ./Scripts/build-app.sh --release
  APP="dist/${APP_NAME}.app"
fi

# ---------------------------------------------------------------------------
# 4. Verify the signature before spending time on Apple's queue.
#
# Notarization rejects anything without the hardened runtime, and it is much
# cheaper to find that out here than fifteen minutes into a submission.
# ---------------------------------------------------------------------------
step "Verifying signature"
SIG="$(codesign -dvvv "$APP" 2>&1)"

grep -q "Developer ID Application" <<<"$SIG" \
  || fail "not signed with a Developer ID certificate:
$(grep '^Authority' <<<"$SIG" | head -1)"

grep -q "flags=.*runtime" <<<"$SIG" \
  || fail "hardened runtime is not enabled; notarization would reject this"

grep -q "^Timestamp=" <<<"$SIG" \
  || fail "no secure timestamp; re-sign with --timestamp"

codesign --verify --strict --deep "$APP" 2>/dev/null \
  || fail "signature does not verify"

echo "    Developer ID · hardened runtime · secure timestamp · verifies"

# The bundle must actually claim the version we are about to publish. This is
# the backstop that would have caught v1.0.6 shipping as 1.0.2.
BUNDLE_VERSION="$(
  plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "?"
)"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
  fail "bundle reports version '$BUNDLE_VERSION' but this release is '$VERSION'.
  Publishing that would mislabel the binary. Rebuild without --app, or fix
  Resources/Info.plist."
fi
echo "    bundle reports $BUNDLE_VERSION"

# Tag the commit that actually produced this build, so a bug report can be
# traced back to source.
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "    built from $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (dirty)')"
fi

# ---------------------------------------------------------------------------
# 5. Notarize, unless the bundle already carries a ticket.
# ---------------------------------------------------------------------------
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  step "Notarization"
  echo "    already stapled — skipping submission"
elif [[ "$SKIP_NOTARIZE" == "1" ]]; then
  step "Notarization"
  echo "    skipped (--skip-notarize); the result will NOT open on other Macs"
else
  step "Notarizing (this waits on Apple; usually a few minutes)"

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "no notarytool credentials under profile '$NOTARY_PROFILE'.

  Store them once (needs an app-specific password from appleid.apple.com):

    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
      --apple-id you@example.com --team-id YOURTEAMID

  Then re-run this script. Or pass --skip-notarize to package without it."
  fi

  SUBMIT_ZIP="$(mktemp -d)/${APP_NAME}-submit.zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
  xcrun notarytool submit "$SUBMIT_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait \
    || fail "notarization failed; run 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE' for the reason"

  step "Stapling"
  # Staple the bundle, not the zip: the ticket must travel inside the .app so
  # it validates without a network round trip on the recipient's machine.
  xcrun stapler staple "$APP"
fi

# ---------------------------------------------------------------------------
# 6. Prove it the way the recipient's Mac will see it.
# ---------------------------------------------------------------------------
step "Gatekeeper"
ASSESS="$(spctl -a -vvv -t install "$APP" 2>&1 || true)"
echo "$ASSESS" | sed 's/^/    /'
grep -q "accepted" <<<"$ASSESS" || fail "Gatekeeper rejected the bundle"
grep -q "Notarized Developer ID" <<<"$ASSESS" \
  || fail "accepted, but not as a notarized build"

# The check above runs on the machine that built it. Re-run it on a copy
# carrying a download quarantine flag, which is what actually reaches a user.
QT="$(mktemp -d)/${APP_NAME}.app"
cp -R "$APP" "$QT"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$QT" 2>/dev/null || true
grep -q "accepted" <<<"$(spctl -a -vvv -t install "$QT" 2>&1 || true)" \
  || fail "rejected once quarantined — it would not open as a download"
rm -rf "$(dirname "$QT")"
echo "    passes with a download quarantine flag too"

# ---------------------------------------------------------------------------
# 7. Package.
# ---------------------------------------------------------------------------
step "Packaging"
mkdir -p dist
# The disk image is the only published artifact.
#
# A .zip alongside it invites the question "which one do I want?", and the
# honest answer is "always the dmg" — so shipping both only creates a wrong
# choice to make. A zip is still produced internally to submit the app for
# notarization; it just never leaves the temp directory.
DMG="dist/${APP_NAME}-${VERSION}.dmg"
./Scripts/make-dmg.sh "$VERSION" --app "$APP" >/dev/null
[[ -f "$DMG" ]] || fail "DMG was not produced"

# The .dmg is its own distributable and needs its own ticket: Gatekeeper
# assesses the container the user actually double-clicks, not just the app
# inside it. Stapling the app alone leaves the disk image unnotarized.
if [[ "$SKIP_NOTARIZE" != "1" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "    DMG already stapled"
  else
    step "Notarizing the disk image"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG" >/dev/null 2>&1 || true
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
      || fail "DMG notarization failed"
    xcrun stapler staple "$DMG"
  fi
  ASSESS_DMG="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
  grep -q "accepted" <<<"$ASSESS_DMG" || fail "Gatekeeper rejected the disk image"
  echo "    disk image accepted by Gatekeeper"
else
  echo "    (DMG not notarized — it will warn on other Macs)"
fi

( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "    $(du -h "$DMG" | cut -f1)  $DMG"

# ---------------------------------------------------------------------------
# 8. Publish.
# ---------------------------------------------------------------------------
if [[ "$PUBLISH" == "0" ]]; then
  step "Done (not published)"
  echo "    $DMG"
  exit 0
fi

step "GitHub release $TAG"
command -v gh >/dev/null || fail "gh CLI not installed"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "    $TAG exists — uploading assets"
  gh release upload "$TAG" "$DMG" "${DMG}.sha256" --clobber
else
  ARGS=(--title "$APP_NAME $VERSION" --notes-file -)
  [[ "$DRAFT" == "1" ]] && ARGS+=(--draft)
  # Notes are built in a *quoted* heredoc.
  #
  # An unquoted one runs command substitution on its contents, so markdown
  # backticks are executed as shell commands and silently deleted: `.dmg` in
  # the install line published as "download the , open it", with a
  # ".dmg: command not found" in the log that nobody read.
  #
  # Checksums are appended afterwards rather than interpolated, so nothing in
  # this text is ever evaluated.
  NOTES="$(mktemp)"
  cat > "$NOTES" <<'NOTES_EOF'
<p align="center">
  <img src="https://raw.githubusercontent.com/melucasleite/claude-usage-widget/main/docs/icon.png" width="128" alt="Claude Usage Widget">
</p>

Your Claude Code usage as Apple-Watch-style activity rings — 5-hour window,
weekly, and Fable.

**Install:** download the `.dmg`, open it, drag the app to Applications.

**Requires** macOS 14+ and Claude Code signed in on this Mac. The widget reads
the credential Claude Code already stores — only ever read, never copied. A
`claude setup-token` token will not work here: the usage endpoint requires the
`user:profile` scope, which only the interactive sign-in grants.

```
NOTES_EOF

  # Bare filenames, not paths: a checksum file is useless if `shasum -c` cannot
  # resolve the name from wherever the user downloaded it.
  printf '%s  %s\n' "$(shasum -a 256 "$DMG" | awk '{print $1}')" \
    "$(basename "$DMG")" >> "$NOTES"
  printf '```\n' >> "$NOTES"

  ARGS=(--title "$APP_NAME $VERSION" --notes-file "$NOTES")
  [[ "$DRAFT" == "1" ]] && ARGS+=(--draft)
  gh release create "$TAG" "$DMG" "${DMG}.sha256" "${ARGS[@]}"
  rm -f "$NOTES"
fi

step "Released"
gh release view "$TAG" --json url -q .url
