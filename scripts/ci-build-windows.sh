#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VCPKG_ROOT="$ROOT/build/ci-vcpkg-windows"
TRIPLET="x64-mingw-static"
BUILD_DIR="$ROOT/build/ci-windows"
DIST_DIR="$ROOT/dist/qdl-windows-x86_64"
CROSS_FILE="$BUILD_DIR/x86_64-w64-mingw32.ini"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
	rm -rf "$VCPKG_ROOT"
	git clone --depth=1 https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
	"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

"$VCPKG_ROOT/vcpkg" install \
	libusb \
	libxml2 \
	libzip \
	--triplet "$TRIPLET"

cat >"$CROSS_FILE" <<EOF
[binaries]
c = 'x86_64-w64-mingw32-gcc'
ar = 'x86_64-w64-mingw32-gcc-ar'
strip = 'x86_64-w64-mingw32-strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '$VCPKG_ROOT/installed/$TRIPLET/lib/pkgconfig'
needs_exe_wrapper = true

[built-in options]
default_library = 'static'
c_link_args = ['-static', '-static-libgcc']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

export PKG_CONFIG_ALLOW_CROSS=1

meson setup "$BUILD_DIR" \
	--cross-file "$CROSS_FILE" \
	--buildtype=release \
	-Dtests=disabled
meson compile -C "$BUILD_DIR"

x86_64-w64-mingw32-strip "$BUILD_DIR/qdl.exe"
cp "$BUILD_DIR/qdl.exe" "$DIST_DIR/"
file "$DIST_DIR/qdl.exe"
