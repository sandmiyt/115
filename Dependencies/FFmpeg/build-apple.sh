#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION=8.0.2
SHA256=5d16962332603c427b3d0887fc12b9166d6ee2cb1108b1865dd2d5eb06a09505
WORK="$ROOT/Generated"
SOURCE="$WORK/ffmpeg-$VERSION"
ARCHIVE="$WORK/ffmpeg-$VERSION.tar.xz"
OUTPUT="$WORK/CinevaFFmpeg.xcframework"
mkdir -p "$WORK"
# Cache keys include this script, bridge, source checksum and the Xcode version.
if [[ -d "$OUTPUT" ]]; then
  echo "Using previously built CinevaFFmpeg XCFramework"
  exit 0
fi
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --connect-timeout 20 \
    "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
if [[ ! -d "$SOURCE" ]]; then tar -xf "$ARCHIVE" -C "$WORK"; fi
for change in "$ROOT"/Patches/*.patch; do
  if patch -t --forward --dry-run -p1 -d "$SOURCE" < "$change" >/dev/null; then
    patch -t --forward -p1 -d "$SOURCE" < "$change"
  else
    # Reusing an already patched local source is allowed; drift is not.
    patch -t --dry-run -R -p1 -d "$SOURCE" < "$change" >/dev/null
  fi
done

build_slice() {
  local sdk="$1" triple="$2" platform="$3"
  local sdkpath compiler prefix build framework
  sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  compiler="$(xcrun --sdk "$sdk" --find clang)"
  prefix="$WORK/$sdk/install"
  build="$WORK/$sdk/build"
  framework="$WORK/$sdk/CinevaFFmpeg.framework"
  mkdir -p "$build" "$framework/Headers" "$framework/Modules"
  (
    cd "$build"
    "$SOURCE/configure" --prefix="$prefix" --target-os=darwin --arch=aarch64 \
      --enable-cross-compile --cc="$compiler" --sysroot="$sdkpath" \
      --extra-cflags="-target $triple -fPIC" \
      --extra-ldflags="-target $triple" \
      --enable-static --disable-shared --enable-pic --enable-pthreads \
      --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 \
      --disable-programs --disable-doc --disable-debug --disable-encoders \
      --disable-muxers --disable-avdevice --disable-avfilter \
      --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
      --enable-zlib --enable-bzlib --enable-iconv
    grep -q '^#define CONFIG_GPL 0' config.h
    grep -q '^#define CONFIG_NONFREE 0' config.h
    grep -q '^#define CONFIG_VIDEOTOOLBOX 1' config.h
    make -j "$(sysctl -n hw.logicalcpu)"
    make install
    cp config.h "$framework/FFmpeg-build-config.h"
    cp ffbuild/config.mak "$framework/FFmpeg-build-config.mak"
  )
  local libs=()
  for name in avformat avcodec swresample swscale avutil; do
    libs+=("-Wl,-force_load,$prefix/lib/lib$name.a")
  done
  # Only our prefixed bridge is public. libav* symbols must stay private so
  # VLCKit's independently built FFmpeg cannot bind to this library's ABI.
  cat > "$build/exports.txt" <<'EXPORTS'
_CinevaFFmpegVersion
_CinevaFFmpegConfiguration
_CinevaFFmpegLicense
_CinevaFFmpegHasDecoder
_CinevaFFmpegHasDemuxer
_CinevaFFmpegHasVideoToolbox
_CinevaFFmpegRuntimeCheck
_CinevaFFmpegSessionCreate
_CinevaFFmpegSessionCancel
_CinevaFFmpegSessionDestroy
_CinevaFFmpegSessionSeek
_CinevaFFmpegSessionSetPosition
_CinevaFFmpegSessionSnapshot
_CinevaFFmpegSessionCopyFrame
_CinevaFFmpegCodecName
EXPORTS
  "$compiler" -target "$triple" -isysroot "$sdkpath" -dynamiclib \
    -std=c11 -O2 -I "$prefix/include" -I "$ROOT/Bridge" "$ROOT"/Bridge/*.c \
    "${libs[@]}" -Wl,-exported_symbols_list,"$build/exports.txt" \
    -Wl,-install_name,@rpath/CinevaFFmpeg.framework/CinevaFFmpeg \
    -Wl,-compatibility_version,8.0 -Wl,-current_version,8.0.2 \
    -framework Foundation -framework CoreFoundation -framework CoreMedia \
    -framework CoreVideo -framework VideoToolbox -framework AudioToolbox \
    -framework CoreAudio -framework Security -framework QuartzCore \
    -lz -lbz2 -liconv -lresolv -lm \
    -o "$framework/CinevaFFmpeg"
  xcrun nm -gjU "$framework/CinevaFFmpeg" > "$build/actual-exports.txt"
  if grep -Ev '^_CinevaFFmpeg[A-Za-z]+$' "$build/actual-exports.txt"; then
    echo "Unexpected public FFmpeg symbols" >&2; exit 1
  fi
  cp "$ROOT/Bridge/CinevaFFmpeg.h" "$framework/Headers/"
  printf 'framework module CinevaFFmpeg {\n  umbrella header "CinevaFFmpeg.h"\n  export *\n}\n' > "$framework/Modules/module.modulemap"
  cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CinevaFFmpeg</string>
<key>CFBundleIdentifier</key><string>com.cineva.ffmpeg</string>
<key>CFBundleName</key><string>CinevaFFmpeg</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict></plist>
PLIST
  # Include the upstream LGPL source plus every applied patch/build input in
  # each platform framework; only the selected slice is embedded in the IPA.
  cp "$ARCHIVE" "$framework/"
  cp "$SOURCE/COPYING.LGPLv2.1" "$framework/FFmpeg-LICENSE.txt"
  cp "$0" "$framework/FFmpeg-build.sh"
  cp -R "$ROOT/Bridge" "$framework/BridgeSource"
  cp -R "$ROOT/Patches" "$framework/Patches"
  printf 'FFmpeg %s\nUpstream SHA256: %s\nSource modifications: bundled Patches/require-hardware.patch\n' "$VERSION" "$SHA256" > "$framework/FFmpeg-provenance.txt"
}

build_slice iphoneos arm64-apple-ios17.0 iPhoneOS
build_slice iphonesimulator arm64-apple-ios17.0-simulator iPhoneSimulator
xcodebuild -create-xcframework \
  -framework "$WORK/iphoneos/CinevaFFmpeg.framework" \
  -framework "$WORK/iphonesimulator/CinevaFFmpeg.framework" -output "$OUTPUT"
