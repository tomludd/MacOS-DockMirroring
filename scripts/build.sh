#!/bin/zsh
# Bygger MacDockEverywhere.app i ./build
#
# Signering (Tilgjengelighet/Skjermopptak er knyttet til signaturen):
#   ./scripts/build.sh                         ad-hoc. Sikrest, men macOS spør om tillatelsene på nytt etter hver bygging.
#   SIGN_IDENTITY="Apple Development: …" ./scripts/build.sh
#                                              signer med eget sertifikat. Tillatelsene beholdes og er knyttet til sertifikatet.
#   KEEP_PERMISSIONS=1 ./scripts/build.sh      ad-hoc med fast identifikator. Tillatelsene beholdes, men ethvert program
#                                              signert med samme identifikator arver dem. Kun for egen utvikling.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="no.kihlstrom.MacDockEverywhere"
APP="build/MacDockEverywhere.app"

# zsh avbryter ikke på en feilende rørledning her selv med `set -e`, så sjekk eksplisitt.
if ! swift build -c release 2>&1 | { grep -v '^\[' || true; }; then
  echo "Bygging feilet" >&2
  exit 1
fi
BIN="$(swift build -c release --show-bin-path)/MacDockEverywhere"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacDockEverywhere"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime "$APP"
elif [[ "${KEEP_PERMISSIONS:-0}" == "1" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "Ferdig: $APP"
