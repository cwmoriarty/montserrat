#!/bin/bash
# Download and build filesystem engines for FUSE-T:
#   - ntfs-3g:            NTFS driver and ntfsprogs (mkntfs, ntfsfix, ntfslabel)
#   - e2fsprogs:          fuse2fs, mke2fs, e2fsck, tune2fs, e2label, debugfs
#   - legacyfs:           liblegacyfs.a, legacyfs, legacyfs-mount, and fuse-* aliases
#   - montserrat-drivers: xfsfuse, btrfsfuse, mkxfs, mkbtrfs, xfsck, btrfsck, montserrat-mapper
#
# Engine libraries are linked statically. The only dynamic runtime
# dependency is FUSE-T located in /usr/local/lib.
#
# Universal binaries are produced by compiling each slice and combining via lipo.
#
# Usage: ./build-engines.sh [all|ntfs-3g|e2fsprogs|legacyfs|montserrat-drivers]
# Environment variables:
#   FUSE_T_PREFIX  FUSE-T header and library path (default /usr/local)
#   PREFIX         Installation prefix for engines (default out)
#   DESTDIR        Optional staging directory
#   BUILD_DIR      Intermediate build directory
#   ARCHS          Target architectures (default "arm64 x86_64")
#   JOBS           Parallel compilation jobs
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$HERE/versions.env"

SRC="$HERE/src"
BUILD="${BUILD_DIR:-$HERE/build}"
PREFIX="${PREFIX:-$HERE/out}"
DESTDIR="${DESTDIR:-}"
ARCHS="${ARCHS:-arm64 x86_64}"
NATIVE_ARCH="$(uname -m)"
FUSE_T_PREFIX="${FUSE_T_PREFIX:-/usr/local}"
FUSE_T_RUNTIME_LIBDIR=/usr/local/lib
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

check_fuse_t() {
	[ -f "$FUSE_T_PREFIX/include/fuse/fuse.h" ] && [ -f "$FUSE_T_PREFIX/include/fuse3/fuse.h" ] ||
		die "FUSE-T headers not found in $FUSE_T_PREFIX/include. Install FUSE-T via:
  brew install --cask macos-fuse-t/homebrew-cask/fuse-t"
	[ -e "$FUSE_T_PREFIX/lib/libfuse-t.dylib" ] && [ -e "$FUSE_T_PREFIX/lib/libfuse3.dylib" ] ||
		die "FUSE-T libraries not found in $FUSE_T_PREFIX/lib"
}

fetch() {
	local file="$SRC/$1" primary_url="$2" sha="$3" fallback_url="${4:-}"
	mkdir -p "$SRC"
	if [ ! -f "$file" ]; then
		log "Downloading $1"
		if ! curl -fL -A "Mozilla/5.0" --retry 3 -o "$file.part" "$primary_url"; then
			if [ -n "$fallback_url" ]; then
				log "Primary download failed; trying fallback URL for $1"
				curl -fL -A "Mozilla/5.0" --retry 3 -o "$file.part" "$fallback_url"
			else
				exit 1
			fi
		fi
		mv "$file.part" "$file"
	fi
	echo "$sha  $file" | shasum -a 256 -c - >/dev/null || die "SHA-256 checksum mismatch for $1"
}

unpack() {
	mkdir -p "$4"
	rm -rf "${4:?}/$2"
	tar -xf "$SRC/$1" -C "$4"
	cd "$4/$2"
	local p
	for p in "$HERE/patches/$3"/*.patch; do
		[ -f "$p" ] || continue
		log "Applying $(basename "$p")"
		patch -p1 --forward < "$p"
	done
}

arch_args() {
	ARCH_ARGS=(CC="cc -arch $1")
	if [ "$1" != "$NATIVE_ARCH" ]; then
		case "$1" in
		arm64) ARCH_ARGS+=(--host=aarch64-apple-darwin) ;;
		*) ARCH_ARGS+=(--host="$1-apple-darwin") ;;
		esac
	fi
}

build_ntfs3g() {
	local tarball="ntfs-3g_ntfsprogs-$NTFS3G_VERSION.tgz" root="$BUILD/$1"
	fetch "$tarball" "$NTFS3G_URL" "$NTFS3G_SHA256" "${NTFS3G_FALLBACK_URL:-}"
	unpack "$tarball" "ntfs-3g-$NTFS3G_VERSION" ntfs-3g "$root"
	arch_args "$1"

	log "Configuring ntfs-3g $NTFS3G_VERSION ($1)"
	./configure \
		--prefix="$PREFIX" --exec-prefix="$PREFIX" \
		--with-fuse=external \
		--disable-shared --enable-static --disable-library \
		--disable-ldconfig --disable-mtab --disable-plugins \
		--without-hd \
		"${ARCH_ARGS[@]}" \
		PKG_CONFIG=/usr/bin/true \
		FUSE_MODULE_CFLAGS="-I$FUSE_T_PREFIX/include/fuse -D_FILE_OFFSET_BITS=64" \
		FUSE_MODULE_LIBS="-L$FUSE_T_PREFIX/lib -lfuse-t -Wl,-rpath,$FUSE_T_RUNTIME_LIBDIR"

	log "Compiling ntfs-3g ($1)"
	make -j"$JOBS"
	make install DESTDIR="$root/stage"
}

build_e2fsprogs() {
	local tarball="e2fsprogs-$E2FSPROGS_VERSION.tar.xz" root="$BUILD/$1"
	fetch "$tarball" "$E2FSPROGS_URL" "$E2FSPROGS_SHA256" "${E2FSPROGS_FALLBACK_URL:-}"
	unpack "$tarball" "e2fsprogs-$E2FSPROGS_VERSION" e2fsprogs "$root"
	arch_args "$1"

	log "Configuring e2fsprogs $E2FSPROGS_VERSION ($1)"
	./configure \
		--prefix="$PREFIX" \
		--enable-fuse2fs \
		--disable-nls --disable-e2initrd-helper --disable-fsck --disable-uuidd \
		--without-libarchive \
		"${ARCH_ARGS[@]}" \
		MKDIR_P="mkdir -p" \
		fuse3_CFLAGS="-I$FUSE_T_PREFIX/include/fuse3" \
		fuse3_LIBS="-L$FUSE_T_PREFIX/lib -lfuse3 -Wl,-rpath,$FUSE_T_RUNTIME_LIBDIR"

	log "Compiling e2fsprogs ($1)"
	make -j"$JOBS"
	make install DESTDIR="$root/stage"
}

build_legacyfs() {
	local tarball="legacyfs-$LEGACYFS_VERSION.tar.gz" root="$BUILD/$1"
	fetch "$tarball" "$LEGACYFS_URL" "$LEGACYFS_SHA256"
	unpack "$tarball" "legacyfs-$LEGACYFS_VERSION" legacyfs "$root"

	log "Compiling legacyfs $LEGACYFS_VERSION ($1)"
	make -j"$JOBS" \
		CC="cc -arch $1" \
		WITH_FUSE=1 \
		FUSE_PREFIX="$FUSE_T_PREFIX" \
		FUSE_CFLAGS="-I$FUSE_T_PREFIX/include/fuse3" \
		FUSE_LIBS="-L$FUSE_T_PREFIX/lib -lfuse3 -Wl,-rpath,$FUSE_T_RUNTIME_LIBDIR -lpthread"
	make install \
		WITH_FUSE=1 \
		PREFIX="$PREFIX" \
		DESTDIR="$root/stage"
}

build_apple_explorer() {
	local tarball="apple-explorer-$APPLE_EXPLORER_VERSION.tar.gz" root="$BUILD/$1"
	fetch "$tarball" "$APPLE_EXPLORER_URL" "$APPLE_EXPLORER_SHA256"
	unpack "$tarball" "apple-explorer-$APPLE_EXPLORER_VERSION" apple-explorer "$root"

	log "Compiling apple-explorer $APPLE_EXPLORER_VERSION ($1)"
	make -j"$JOBS" \
		CC="cc -arch $1" \
		WITH_FUSE=1 \
		FUSE_PREFIX="$FUSE_T_PREFIX" \
		FUSE_CFLAGS="-I$FUSE_T_PREFIX/include/fuse3" \
		FUSE_LIBS="-L$FUSE_T_PREFIX/lib -lfuse3 -Wl,-rpath,$FUSE_T_RUNTIME_LIBDIR -lpthread"
	make install \
		WITH_FUSE=1 \
		PREFIX="$PREFIX" \
		DESTDIR="$root/stage"
}

build_montserrat_drivers() {
	local root="$BUILD/$1" drv_build="$BUILD/$1/montserrat-drivers"
	rm -rf "$drv_build"
	mkdir -p "$drv_build"

	log "Compiling montserrat-drivers (XFS, Btrfs, LUKS/Argon2id, Multi-PV LVM2, RAID, sparsebundle mapper) ($1)"
	make -C "$HERE/montserrat-drivers" -j"$JOBS" \
		CC="cc -arch $1" \
		BUILD="$drv_build" \
		COWFS_DIR="$HERE/../Sources/CCowFS" \
		AEX_INC="$root/stage$PREFIX/include" \
		AEX_LIB="$root/stage$PREFIX/lib/libappleexplorer.a" \
		FUSE_PREFIX="$FUSE_T_PREFIX" \
		FUSE_CFLAGS="-I$FUSE_T_PREFIX/include/fuse3" \
		FUSE_LIBS="-L$FUSE_T_PREFIX/lib -lfuse3 -Wl,-rpath,$FUSE_T_RUNTIME_LIBDIR"
	make -C "$HERE/montserrat-drivers" install \
		CC="cc -arch $1" \
		BUILD="$drv_build" \
		COWFS_DIR="$HERE/../Sources/CCowFS" \
		AEX_INC="$root/stage$PREFIX/include" \
		AEX_LIB="$root/stage$PREFIX/lib/libappleexplorer.a" \
		FUSE_PREFIX="$FUSE_T_PREFIX" \
		PREFIX="$PREFIX" \
		DESTDIR="$root/stage"
}

merge_archs() {
	local first="${ARCHS%% *}" dest="$DESTDIR$PREFIX" src rel a
	local slices=()
	src="$BUILD/$first/stage$PREFIX"
	log "Merging architecture slices ($ARCHS) into $dest"
	mkdir -p "$dest"
	(cd "$src" && find . -type d) | while IFS= read -r rel; do mkdir -p "$dest/$rel"; done
	(cd "$src" && find . -type f -o -type l) | while IFS= read -r rel; do
		rm -f "$dest/$rel"
		if [ ! -L "$src/$rel" ] && lipo -archs "$src/$rel" >/dev/null 2>&1; then
			slices=()
			for a in $ARCHS; do slices+=("$BUILD/$a/stage$PREFIX/$rel"); done
			lipo -create "${slices[@]}" -output "$dest/$rel"
			chmod "$(stat -f %Lp "$src/$rel")" "$dest/$rel"
			if file -b "$dest/$rel" | grep -q executable; then
				codesign --sign - --force "$dest/$rel" 2>/dev/null
			fi
		else
			cp -pP "$src/$rel" "$dest/$rel"
		fi
	done
	# Remove vendored uuid headers so they do not shadow macOS SDK uuid/uuid.h
	rm -rf "$dest/include/uuid"
}

report() {
	local out="$DESTDIR$PREFIX" f
	log "Binaries in $out: architectures and dynamic dependencies"
	for f in "$out"/bin/ntfs-3g "$out"/bin/fuse2fs "$out"/bin/xfsfuse "$out"/bin/btrfsfuse \
		"$out"/bin/montserrat-mapper "$out"/bin/legacyfs "$out"/bin/legacyfs-mount \
		"$out"/bin/apple-explorer "$out"/bin/apple-explorer-mount \
		"$out"/sbin/mkntfs "$out"/bin/ntfsfix "$out"/sbin/mke2fs "$out"/sbin/e2fsck \
		"$out"/sbin/mkxfs "$out"/sbin/xfsck "$out"/sbin/mkbtrfs "$out"/sbin/btrfsck; do
		[ -x "$f" ] || continue
		echo "${f#"$out"/} [$(lipo -archs "$f")]:"
		otool -L "$f" | grep -v -e ':$' -e libSystem | sort -u || true
	done
}

target="${1:-all}"
case "$target" in
all | ntfs-3g | e2fsprogs | legacyfs | apple-explorer | montserrat-drivers) ;;
*) die "unknown target: $target (all|ntfs-3g|e2fsprogs|legacyfs|apple-explorer|montserrat-drivers)" ;;
esac
check_fuse_t
for arch in $ARCHS; do
	rm -rf "${BUILD:?}/$arch/stage"
	case "$target" in
	all) build_ntfs3g "$arch"; build_e2fsprogs "$arch"; build_legacyfs "$arch"; build_apple_explorer "$arch"; build_montserrat_drivers "$arch" ;;
	ntfs-3g) build_ntfs3g "$arch" ;;
	e2fsprogs) build_e2fsprogs "$arch" ;;
	legacyfs) build_legacyfs "$arch" ;;
	apple-explorer) build_apple_explorer "$arch" ;;
	montserrat-drivers) build_apple_explorer "$arch"; build_montserrat_drivers "$arch" ;;
	esac
done
merge_archs
report
