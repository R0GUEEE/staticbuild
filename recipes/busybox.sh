#!/bin/sh
# deps: build-base
# BusyBox — 400 applets in one file. Recipes use it as the shell layer for
# anything that expects `sh`, `sed`, `awk`, `xargs` to exist inside a sandbox.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://busybox.net/downloads/busybox-$SB_VERSION.tar.tar.bz2" "" ) 2>/dev/null || \
src=$(sb_fetch "https://git.busybox.net/busybox/snapshot/busybox-$SB_VERSION.tar.bz2")
sb_unpack "$src" "$SB_WORK/src/busybox"
cd "$SB_WORK/src/busybox/busybox-$SB_VERSION"

# The allnoconfig base keeps the binary near 900 KiB; the fragment turns back on
# what a build tool actually shells out to.
cat > "$SB_WORK/bb.fragment" <<'EOF'
CONFIG_STATIC=y
CONFIG_PIE=y
CONFIG_DESKTOP=n
CONFIG_LONG_OPTS=y
CONFIG_FEATURE_EDITING=y
CONFIG_FEATURE_EDITING_HISTORY=256
CONFIG_ASH=y
CONFIG_ASH_BASH_COMPAT=y
CONFIG_ASH_JOB_CONTROL=y
CONFIG_ASH_ALIAS=y
CONFIG_SED=y
CONFIG_GREP=y
CONFIG_EGREP=y
CONFIG_FGREP=y
CONFIG_AWK=y
CONFIG_FIND=y
CONFIG_XARGS=y
CONFIG_TAR=y
CONFIG_GZIP=y
CONFIG_BZIP2=y
CONFIG_XZ=y
CONFIG_UNZIP=y
CONFIG_WGET=y
CONFIG_SHA256SUM=y
CONFIG_MD5SUM=y
CONFIG_DIFF=y
CONFIG_PATCH=y
CONFIG_VI=y
CONFIG_LESS=y
CONFIG_WHICH=y
CONFIG_ENV=y
CONFIG_TEST=y
CONFIG_TIMEOUT=y
CONFIG_FLOCK=y
CONFIG_STAT=y
CONFIG_READLINK=y
CONFIG_REALPATH=y
CONFIG_MKTEMP=y
CONFIG_INSTALL=y
CONFIG_PRINTF=y
CONFIG_SEQ=y
CONFIG_TR=y
CONFIG_CUT=y
CONFIG_PASTE=y
CONFIG_SORT=y
CONFIG_UNIQ=y
CONFIG_NL=y
CONFIG_OD=y
CONFIG_HEXDUMP=y
CONFIG_BASE64=y
CONFIG_XXD=y
EOF

[ "$SB_TARGET" = ios-arm64 ] && echo "CONFIG_STATIC=n" >> "$SB_WORK/bb.fragment"
echo "CONFIG_CROSS_COMPILER_PREFIX=\"\"" >> "$SB_WORK/bb.fragment"

make defconfig
while read -r line; do
  key=${line%%=*}
  grep -q "^$key=" .config && sed -i "s|^$key=.*|$line|" .config || echo "$line" >> .config
done < "$SB_WORK/bb.fragment"
yes "" | make oldconfig >/dev/null 2>&1 || true
make -j "$SB_JOBS" CFLAGS_EXTRA="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"

sb_bin busybox busybox
SB_PATHS=bin
sb_finish
