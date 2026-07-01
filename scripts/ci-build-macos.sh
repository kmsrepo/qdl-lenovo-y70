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

find_llvm_tool() {
	local tool="$1"
	local candidate

	if command -v "$tool" >/dev/null 2>&1; then
		command -v "$tool"
		return
	fi

	for candidate in /usr/bin/"$tool"-* /usr/lib/llvm-*/bin/"$tool"; do
		if [ -x "$candidate" ]; then
			echo "$candidate"
			return
		fi
	done
}

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
MESON_AR="$(find_llvm_tool llvm-ar)"
MESON_RANLIB="$(find_llvm_tool llvm-ranlib)"

if [ -z "$MESON_AR" ] || [ -z "$MESON_RANLIB" ]; then
	echo "llvm-ar and llvm-ranlib are required for the macOS Meson archive step" >&2
	exit 1
fi

export PATH="$OSXCROSS_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$OSXCROSS_DIR/lib:/usr/lib/x86_64-linux-gnu:/usr/lib:${LD_LIBRARY_PATH:-}"

for tool in install_name_tool lipo otool; do
	target="$(find "$OSXCROSS_DIR/bin" -maxdepth 1 \( -type f -o -type l \) -name "x86_64-apple-darwin*-$tool" | sort -V | tail -n 1)"
	if [ -n "$target" ]; then
		ln -sf "$(basename "$target")" "$OSXCROSS_DIR/bin/$tool"
	fi
done

for libxml in /usr/lib/x86_64-linux-gnu/libxml2.so.2 /usr/lib/libxml2.so.2; do
	if [ -e "$libxml" ]; then
		ln -sf "$libxml" "$OSXCROSS_DIR/lib/libxml2.so.2"
		break
	fi
done

if command -v patchelf >/dev/null 2>&1; then
	for f in "$OSXCROSS_DIR"/bin/*-ld "$OSXCROSS_DIR"/lib/*.so*; do
		[ -e "$f" ] || continue
		patchelf --set-rpath "$OSXCROSS_DIR/lib:/usr/lib/x86_64-linux-gnu:/usr/lib" "$f" 2>/dev/null || true
	done
fi

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

if ! "$VCPKG_ROOT/vcpkg" install \
		libusb \
		libxml2 \
		libzip \
		--overlay-triplets "$TRIPLET_DIR" \
		--triplet "$TRIPLET"; then
	find "$VCPKG_ROOT/buildtrees" -path '*detect_compiler*' -type f \
		\( -name '*-out.log' -o -name '*-err.log' \) -print \
		-exec sed -n '1,180p' {} \; || true
	exit 1
fi

cat >"$CROSS_FILE" <<EOF
[binaries]
c = '$OSXCROSS_DIR/bin/o64-clang'
ar = '$MESON_AR'
ranlib = '$MESON_RANLIB'
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

meson setup "$BUILD_DIR" \
	--cross-file "$CROSS_FILE" \
	--buildtype=release \
	-Dtests=disabled
meson compile -C "$BUILD_DIR"

"$STRIP" "$BUILD_DIR/qdl" || true
cp "$BUILD_DIR/qdl" "$DIST_DIR/"
file "$DIST_DIR/qdl"
