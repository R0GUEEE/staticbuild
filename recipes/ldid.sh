#!/bin/sh
# deps: build-base cmake libplist-dev libcrypto++? (ldid: openssl)
# ldid — the signer every jailbreak-adjacent tool needs. Procursus fork:
# it understands entitlements, DER entitlements and ad-hoc signatures on device.
. "$(dirname "$0")/_common.sh"
sb_init

git clone --depth 1 --branch "$SB_VERSION" \
  https://github.com/ProcursusTeam/ldid.git "$SB_WORK/src/ldid" 2>/dev/null || \
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git "$SB_WORK/src/ldid"
cd "$SB_WORK/src/ldid"

# ldid vendors libplist; OPENSSL comes from the system or the openssl recipe.
cmake -B out -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$(sb_cflags)" \
  -DCMAKE_CXX_FLAGS="$(sb_cflags)" \
  -DCMAKE_EXE_LINKER_FLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -L${OPENSSL_PREFIX:-/usr/lib} -lcrypto -lpthread" \
  -DCMAKE_EXE_LINKER_FLAGS_RELEASE="-s"
cmake --build out -j "$SB_JOBS"

sb_bin out/ldid ldid
sb_bin out/ldid ldid2
SB_PATHS=bin
sb_finish
