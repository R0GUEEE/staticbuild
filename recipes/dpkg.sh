#!/bin/sh
# deps: build-base autoconf automake gettext-dev zlib-dev bzip2-dev xz-dev zstd-dev libmd-dev
# dpkg tooling, reduced to what produces and inspects .deb files.
#
# Deliberately not built: dpkg itself as an installer (needs a root-owned
# database, maintainer scripts, dpkg triggers). docs/caveats.md has the list.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://deb.debian.org/debian/pool/main/d/dpkg/dpkg_${SB_VERSION}.tar.xz")
sb_unpack "$src" "$SB_WORK/src/dpkg"
sb_cd "$SB_WORK/src/dpkg/dpkg-$SB_VERSION"

sb_configure --prefix=/usr --disable-shared --enable-static \
  --disable-dselect --disable-start-stop-daemon \
  --disable-update-alternatives --without-libselinux --disable-nls \
  CFLAGS="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static -s)"

make -C lib -j "$SB_JOBS" || die "dpkg: libdpkg failed"
make -C src -j "$SB_JOBS" dpkg-deb dpkg-split dpkg-query 2>/dev/null || \
  make -C src -j "$SB_JOBS" || die "dpkg: tools failed"

for t in dpkg-deb dpkg-split dpkg-query; do
  [ -x "src/$t" ] || die "dpkg: $t was not built"
  sb_bin "src/$t" "$t"
done

# dpkg-deb links libdpkg.a; if the shared build slipped through, fail loudly here
# rather than in a user's bundle.
case "$SB_FAMILY" in
  elf) readelf -d "$SB_STAGE/bin/dpkg-deb" | grep -q NEEDED && die "dpkg-deb is dynamically linked" ;;
esac

export SB_ENTRY=bin/dpkg-deb
export SB_PATHS=bin
sb_finish
