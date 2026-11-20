#!/usr/bin/env bash
# Builds build/KeyGlance.app with swiftc directly (no Xcode or SwiftPM required).
#   ./scripts/build-app.sh                 release build, ad-hoc signed
#   DEBUG=1 ./scripts/build-app.sh         debug build
#   SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh
#     A stable identity keeps the Accessibility grant across rebuilds (ad-hoc signing does not).
#     Defaults to "KeyGlance Dev" when present (create it once with scripts/make-signing-cert.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/KeyGlance.app"
OPT=$([ "${DEBUG:-0}" = "1" ] && echo "-Onone -g" || echo "-O")
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# shellcheck disable=SC2046,SC2086
xcrun swiftc $OPT -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  -module-name KeyGlance \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework SwiftUI -framework Security \
  $(find Sources/KeyGlance -name '*.swift' | sort) \
  -o "$APP/Contents/MacOS/KeyGlance"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# Prefer a stable identity (see make-signing-cert.sh) so Accessibility survives rebuilds.
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "KeyGlance Dev" >/dev/null 2>&1; then
  SIGN_IDENTITY="KeyGlance Dev"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Signed with: ${SIGN_IDENTITY:-ad-hoc}"
echo "Built $APP"
