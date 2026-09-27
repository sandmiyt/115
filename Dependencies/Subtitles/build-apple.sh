#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/Generated"
SDK="$1"; TRIPLE="$2"
PREFIX="$WORK/$SDK/install"
mkdir -p "$WORK/sources" "$PREFIX"
fetch() {
  local archive="$1" hash="$2" url="$3"
  if [[ ! -f "$WORK/sources/$archive" ]]; then
    curl --fail --location --retry 3 --connect-timeout 20 "$url" -o "$WORK/sources/$archive"
  fi
  echo "$hash  $WORK/sources/$archive" | shasum -a 256 -c -
  tar -xf "$WORK/sources/$archive" -C "$WORK/sources"
}
fetch libass-0.17.4.tar.xz 78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz
fetch fribidi-1.0.16.tar.xz 1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
fetch harfbuzz-10.2.0.tar.xz 620e3468faec2ea8685d32c46a58469b850ef63040b3565cde05959825b48227 https://github.com/harfbuzz/harfbuzz/releases/download/10.2.0/harfbuzz-10.2.0.tar.xz
fetch freetype-2.13.3.tar.gz bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103 https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-13-3
if [[ ! -x "$WORK/tools/bin/meson" ]]; then
  python3 -m venv "$WORK/tools"
  "$WORK/tools/bin/pip" install meson==1.7.2 ninja==1.11.1.3
fi
export PATH="$WORK/tools/bin:$PATH"
SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" --find clang)"
CXX="$(xcrun --sdk "$SDK" --find clang++)"
PKGCONFIG="$(command -v pkg-config)"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=""
cat > "$WORK/$SDK/cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = 'ar'
strip = 'strip'
pkg-config = '$PKGCONFIG'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-target', '$TRIPLE', '-isysroot', '$SDKPATH', '-fPIC']
cpp_args = ['-target', '$TRIPLE', '-isysroot', '$SDKPATH', '-fPIC']
c_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDKPATH']
cpp_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDKPATH']
EOF
cmake -S "$WORK/sources/freetype-VER-2-13-3" -B "$WORK/$SDK/freetype" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKPATH" -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake --build "$WORK/$SDK/freetype" --parallel 3
cmake --install "$WORK/$SDK/freetype"
meson_build() {
  local name="$1" source="$2"; shift 2
  meson setup "$WORK/$SDK/$name" "$WORK/sources/$source" --cross-file "$WORK/$SDK/cross.ini" \
    --prefix "$PREFIX" --libdir lib --buildtype release --default-library static \
    -Dauto_features=disabled "$@"
  meson compile -C "$WORK/$SDK/$name" -j 3
  meson install -C "$WORK/$SDK/$name"
}
meson_build fribidi fribidi-1.0.16 -Ddocs=false -Dbin=false -Dtests=false
meson_build harfbuzz harfbuzz-10.2.0 -Dfreetype=enabled -Dcoretext=enabled
meson_build libass libass-0.17.4 -Dcoretext=enabled
mkdir -p "$PREFIX/provenance"
cp "$WORK/sources/"*.tar.* "$PREFIX/provenance/"
cp "$WORK/sources/libass-0.17.4/COPYING" "$PREFIX/provenance/libass-LICENSE"
cp "$WORK/sources/fribidi-1.0.16/COPYING" "$PREFIX/provenance/fribidi-LICENSE"
cp "$WORK/sources/harfbuzz-10.2.0/COPYING" "$PREFIX/provenance/harfbuzz-LICENSE"
cp "$WORK/sources/freetype-VER-2-13-3/docs/FTL.TXT" "$PREFIX/provenance/freetype-LICENSE"
cp "$0" "$PREFIX/provenance/build-apple.sh"
