#!/bin/bash
set -euo pipefail

if ! command -v pod >/dev/null 2>&1; then
  echo "CocoaPods is required because Cineva bundles MobileVLCKit for incompatible original formats."
  echo "Install CocoaPods first, then run this script again."
  exit 1
fi

pod install

xcodebuild \
  -workspace Gallery115.xcworkspace \
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
