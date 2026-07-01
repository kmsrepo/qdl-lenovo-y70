#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${OSXCROSS_IMAGE:-crazymax/osxcross:26.1-r0-ubuntu}"
OSXCROSS_DIR="$ROOT/build/ci-osxcross"
VCPKG_ROOT="$ROOT/build/ci-vcpkg-macos"
TRIPLET_DIR="$ROOT/build/ci-macos-triplets"
TRIPLET="x64-osx-osxcross"
BUILD_DIR="$ROOT/build/ci-macos"
DIST_DIR="$ROOT/dist/qdl-macos-x86_64"
CMAKE_TOOLCHAIN="$TRIPLET_DIR/osxcross-toolchain.cmake"
VCPKG_TRIPLET="$TRIPLET_DIR/$TRIPLET.cmake"
CROSS_FILE="$BUILD_DIR/x86_64-apple-darwin.ini"

if [ ! -x "$OSXCROSS_DIR/bin/o64-clang" ]; then
	rm -rf "$OSXCROSS_DIR" "$OSXCROSS_DIR.tmp"
	docker pull "$IMAGE"
	container_id="$(docker create "$IMAGE" /does-not-need-to-run)"
	trap 'docker rm "$container_id" >/dev/null 2>&1 || true' EXIT
	docker cp "$container_id:/osxcross" "$OSXCROSS_DIR.tmp"
	docker rm "$container_id" >/dev/null
	trap - EXIT
	mv "$OSXCROSS_DIR.tmp" "$OSXCROSS_DIR"
fi

rm -rf "$BUILD_DIR" "$DIST_DIR" "$TRIPLET_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$TRIPLET_DIR"

if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
	rm -rf "$VCPKG_ROOT"
	git clone --depth=1 https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
	"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

SDKROOT="$(find "$OSXCROSS_DIR" -type d -name '*.sdk' | sort -V | tail -n 1)"
AR="$(find "$OSXCROSS_DIR/bin" -maxdepth 1 \( -type f -o -type l \) -name 'x86_64-apple-darwin*-ar' | sort -V | tail -n 1)"
RANLIB="$(find "$OSXCROSS_DIR/bin" -maxdepth 1 \( -type f -o -type l \) -name 'x86_64-apple-darwin*-ranlib' | sort -V | tail -n 1)"
STRIP="$(find "$OSXCROSS_DIR/bin" -maxdepth 1 \( -type f -o -type l \) -name 'x86_64-apple-darwin*-strip' | sort -V | tail -n 1)"

cat >"$CMAKE_TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_OSX_ARCHITECTURES x86_64)
set(CMAKE_OSX_SYSROOT "$SDKROOT")
set(CMAKE_C_COMPILER "$OSXCROSS_DIR/bin/o64-clang")
set(CMAKE_CXX_COMPILER "$OSXCROSS_DIR/bin/o64-clang++")
set(CMAKE_AR "$AR")
set(CMAKE_RANLIB "$RANLIB")
set(CMAKE_FIND_ROOT_PATH "$VCPKG_ROOT/installed/$TRIPLET" "$SDKROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

cat >"$VCPKG_TRIPLET" <<EOF
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES x86_64)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE "$CMAKE_TOOLCHAIN")
EOF

"$VCPKG_ROOT/vcpkg" install \
	libusb \
	libxml2 \
	libzip \
	--overlay-triplets "$TRIPLET_DIR" \
	--triplet "$TRIPLET"

cat >"$CROSS_FILE" <<EOF
[binaries]
c = '$OSXCROSS_DIR/bin/o64-clang'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '$VCPKG_ROOT/installed/$TRIPLET/lib/pkgconfig'
needs_exe_wrapper = true

[built-in options]
default_library = 'static'

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

export PKG_CONFIG_ALLOW_CROSS=1
export PATH="$OSXCROSS_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$OSXCROSS_DIR/lib:${LD_LIBRARY_PATH:-}"

meson setup "$BUILD_DIR" \
	--cross-file "$CROSS_FILE" \
	--buildtype=release \
	-Dtests=disabled
meson compile -C "$BUILD_DIR"

"$STRIP" "$BUILD_DIR/qdl" || true
cp "$BUILD_DIR/qdl" "$DIST_DIR/"
file "$DIST_DIR/qdl"
