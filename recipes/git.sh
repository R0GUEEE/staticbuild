#!/bin/sh
# shellcheck disable=SC2046 # sb_cmake_args/sb_cflags are flag lists
# deps: build-base curl-dev expat-dev zlib-dev openssl-dev perl gettext-dev
# git — core only. git-svn, git-gui, gitk and the docs are deliberately absent:
# they drag in Perl chains and Tcl, and nobody builds iOS apps with gitk.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/git/git/archive/refs/tags/v$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/git"
sb_cd "$SB_WORK/src/git/git-$SB_VERSION"

_ld="$([ "$SB_FAMILY" = elf ] && echo -static -s)"

make -j "$SB_JOBS" \
  prefix=/usr \
  NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease \
  NO_INSTALL_HARDLINKS=YesPlease NO_OPENSSL=YesPlease \
  USE_LIBPCRE2=NoThanks NO_REGEX=NeedsStartEnd \
  CFLAGS="$(sb_cflags)" LDFLAGS="$_ld" \
  all

mkdir -p "$SB_STAGE/libexec"
make prefix=/usr DESTDIR="$SB_WORK/git-dist" NO_PERL=YesPlease install >/dev/null

_p="$SB_WORK/git-dist/usr"
cp "$_p/bin/git" "$SB_STAGE/bin/git"
chmod 755 "$SB_STAGE/bin/git"
# git dispatches to git-<subcommand> helpers; they must be exec'able from GIT_EXEC_PATH
( cd "$_p/libexec/git-core" && tar -cf - . ) | ( cd "$SB_STAGE/libexec" && tar -xf - )

export SB_PATHS="bin"
export SB_ENTRY="bin/git"
export SB_ENV='"GIT_EXEC_PATH": "${ROOT}/libexec", "GIT_TEMPLATE_DIR": "${ROOT}/libexec/templates", "GIT_SSL_CAINFO": "/etc/ssl/certs/ca-certificates.crt"'
sb_finish
