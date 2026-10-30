#!/bin/sh
# deps: build-base autoconf automake libtool gettext-dev libcap-dev
# fakeroot — makes dpkg-deb believe it is root, so .deb files get correct
# ownership without a privileged build host.
. "$(dirname "$0")/_common.sh"
sb_init

sb_git https://salsa.debian.org/cli/fakeroot.git "upstream/$SB_VERSION" fakeroot
sb_cd "$SB_WORK/src/fakeroot"

./bootstrap 2>/dev/null || autoreconf -fi
sb_configure --prefix=/usr --disable-static \
  CFLAGS="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s"
make -j "$SB_JOBS"

sb_bin src/fakeroot fakeroot
sb_bin src/faked faked
mkdir -p "$SB_STAGE/lib/fakeroot"
for l in "$SB_WORK/src/fakeroot"/.libs/libfakeroot*.so*; do
  [ -e "$l" ] || continue
  # fakeroot is injected with LD_PRELOAD; on iOS LD_PRELOAD does not exist,
  # so the Mach-O build is only useful for its faked/fakeroot-tcp split.
  cp -R "$l" "$SB_STAGE/lib/fakeroot/"
done

export SB_PATHS="bin"
export SB_ENTRY="bin/fakeroot"
export SB_ENV='"FAKEROOTKEY": "0", "FAKEROOTDONTTRYCHOWN": "1"'
sb_finish
