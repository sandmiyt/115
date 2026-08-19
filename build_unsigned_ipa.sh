#!/bin/bash
set -euo pipefail

xcodebuild \
  -project Gallery115.xcodeproj \
  -scheme Gallery115 \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="build/Build/Products/Release-iphoneos/Gallery115.app"
test -d "$APP_PATH"
rm -rf Payload Gallery115-unsigned.ipa
mkdir Payload
cp -R "$APP_PATH" Payload/
/usr/bin/zip -qry Gallery115-unsigned.ipa Payload

echo "Created: Gallery115-unsigned.ipa"
