#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build/ci-linux"
DIST_DIR="$ROOT/dist/qdl-linux-x86_64"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

if pkg-config --exists cmocka; then
	TESTS_OPT=enabled
elif [ "${CI:-}" = "true" ]; then
	echo "cmocka is required for Linux CI tests" >&2
	exit 1
else
	TESTS_OPT=disabled
fi

meson setup "$BUILD_DIR" \
	--buildtype=release \
	-Dtests="$TESTS_OPT"
meson compile -C "$BUILD_DIR"
meson test -C "$BUILD_DIR" --print-errorlogs
meson compile manpages -C "$BUILD_DIR"

cp "$BUILD_DIR/qdl" "$DIST_DIR/"
ldd "$BUILD_DIR/qdl" | awk '/=> \//{print $3}' | while read -r lib; do
	case "$lib" in
		*/libc.so.*|*/libm.so.*|*/libpthread.so.*|*/libdl.so.*|*/librt.so.*|*/ld-linux*|*/ld64.so.*) ;;
		*) cp -vL "$lib" "$DIST_DIR/" ;;
	esac
done

chmod 0755 "$DIST_DIR/qdl"
find "$DIST_DIR" -type f ! -name qdl -exec chmod 0644 {} +

if command -v patchelf >/dev/null 2>&1; then
	for f in "$DIST_DIR/qdl" "$DIST_DIR"/*.so*; do
		[ -e "$f" ] || continue
		patchelf --set-rpath '$ORIGIN' "$f"
	done
elif [ "${CI:-}" = "true" ]; then
	echo "patchelf is required for Linux CI packaging" >&2
	exit 1
else
	echo "patchelf not found; skipping local RPATH packaging checks" >&2
	exit 0
fi

if ldd "$DIST_DIR/qdl" | grep -q 'not found'; then
	ldd "$DIST_DIR/qdl"
	echo "qdl has unresolved libraries" >&2
	exit 1
fi

leaked="$(ldd "$DIST_DIR/qdl" | awk '/=> \//{print $3}' \
	| grep -vE '/lib(c|m|pthread|dl|rt)\.so' \
	| grep -v "$DIST_DIR/" || true)"
if [ -n "$leaked" ]; then
	echo "qdl depends on unbundled libraries:" >&2
	echo "$leaked" >&2
	exit 1
fi
