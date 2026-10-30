#!/bin/sh
# shellcheck shell=sh
# iOS cross-compilation layer, sourced by _common.sh for every macho target.
#
# The problem this solves, in one sentence: on a macOS runner an ios-arm64 build
# is a cross build between two identical machines, so every autoconf and cmake
# project dutifully compiles a test program, runs it, gets EPERM because the
# Mach-O is platform iOS, and aborts with "cannot run C compiled programs".
# Nothing about the compiler is wrong; the recipe is describing the wrong world.
#
# The fix has three parts, and all three are needed:
#
#   1. wrappers that carry the SDK, the arch and the deployment target, so `cc`
#      means "iPhoneOS clang" for every project that ignores CFLAGS;
#   2. --build/--host on configure, which is what actually makes autoconf skip
#      its run tests instead of failing on them;
#   3. a CMake toolchain file, because cmake refuses to cross-compile at all
#      unless CMAKE_SYSTEM_NAME is set (it then also skips try_run).
#
# Everything is derived from $SB_TARGET so ios-arm64 and macos-arm64 work from
# the same file.

SB_DEPLOY_MIN=${SB_DEPLOY_MIN:-15.0}

# sb_ios_sdk -> the iPhoneOS SDK path cmake/configure must see
sb_ios_sdk() {
  _s=${IOS_SDK_PATH:-}
  [ -n "$_s" ] || _s=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
  [ -n "$_s" ] || die "no iPhoneOS SDK: xcrun --sdk iphoneos --show-sdk-path is empty"
  printf '%s\n' "$_s"
}

# sb_macho_toolchain -> creates $SB_WORK/bin/sb-cc and friends. Idempotent.
sb_macho_toolchain() {
  _bin=$SB_WORK/bin
  mkdir -p "$_bin"
  _sdk=$(sb_ios_sdk)
  case "$SB_TARGET" in
    ios-arm64)     _flags="-arch arm64 -isysroot $_sdk -miphoneos-version-min=$SB_DEPLOY_MIN" ; _xflags="--sdk iphoneos" ;;
    ios-arm64-sim) _flags="-arch arm64 -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) -mios-simulator-version-min=$SB_DEPLOY_MIN" ; _xflags="--sdk iphonesimulator" ;;
    macos-*)       _flags="-arch $SB_ARCH -mmacosx-version-min=11.0" ; _xflags="" ;;
    *)             die "sb_macho_toolchain: $SB_TARGET is not a macho target" ;;
  esac

  # A wrapper, not a CC string with spaces: many builds quote CC as one word
  # (`$CC $CFLAGS`), and "xcrun -sdk iphoneos clang" in a variable is a classic
  # way to get "-sdk: command not found" out of a Makefile.
  cat > "$_bin/sb-cc" <<EOF
#!/bin/sh
exec xcrun $_xflags clang $_flags "\$@"
EOF
  cat > "$_bin/sb-cxx" <<EOF
#!/bin/sh
exec xcrun $_xflags clang++ $_flags "\$@"
EOF
  for _t in ar ranlib strip nm ld lipo otool install_name_tool; do
    cat > "$_bin/sb-$_t" <<EOF
#!/bin/sh
exec xcrun $_xflags $_t "\$@"
EOF
  done
  chmod 755 "$_bin"/sb-*

  # Never clobber an explicit choice (xtool, a custom clang, zig cc).
  export CC=${CC:-$_bin/sb-cc}
  export CXX=${CXX:-$_bin/sb-cxx}
  export AR=${AR:-$_bin/sb-ar}
  export RANLIB=${RANLIB:-$_bin/sb-ranlib}
  export STRIP=${STRIP:-$_bin/sb-strip}
  export NM=${NM:-$_bin/sb-nm}
  export LD=${LD:-$_bin/sb-ld}
  SB_HOST_TRIPLE=$SB_TRIPLE
  SB_BUILD_TRIPLE=$(uname -m)-apple-darwin
  export SB_HOST_TRIPLE SB_BUILD_TRIPLE
}

# sb_configure ARGS... -> ./configure with the cross identity applied.
# A function, not a PATH shim, because recipes call `./configure` by path.
sb_configure() {
  case "$SB_FAMILY" in
    macho)
      [ -n "${SB_BUILD_TRIPLE:-}" ] || sb_macho_toolchain
      log "configure --build=$SB_BUILD_TRIPLE --host=$SB_HOST_TRIPLE"
      sb_configure --build="$SB_BUILD_TRIPLE" --host="$SB_HOST_TRIPLE" "$@"
      ;;
    *) ./configure "$@" ;;
  esac
}

# sb_cmake_toolchain -> writes the cmake toolchain file, prints its path.
sb_cmake_toolchain() {
  _f=$SB_WORK/macho-toolchain.cmake
  [ -f "$_f" ] && { printf '%s\n' "$_f"; return 0; }
  mkdir -p "$SB_WORK"
  {
    printf 'set(CMAKE_SYSTEM_NAME iOS)\n'
    printf 'set(CMAKE_SYSTEM_PROCESSOR arm64)\n'
    printf 'set(CMAKE_OSX_ARCHITECTURES arm64)\n'
    printf 'set(CMAKE_OSX_DEPLOYMENT_TARGET %s)\n' "$SB_DEPLOY_MIN"
    printf 'set(CMAKE_OSX_SYSROOT %s)\n' "$(sb_ios_sdk)"
    printf 'set(CMAKE_C_COMPILER %s)\n' "${CC:-$(sb_cc)}"
    printf 'set(CMAKE_CXX_COMPILER %s)\n' "${CXX:-$(sb_cc)}"
    printf 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\n'
    printf 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)\n'
    printf 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)\n'
    printf 'set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)\n'
  } > "$_f"
  printf '%s\n' "$_f"
}

# sb_cmake_args -> the flags every cmake invocation needs on iOS.
sb_cmake_args() {
  if [ "$SB_FAMILY" = macho ]; then
    printf '%s\n' "-DCMAKE_TOOLCHAIN_FILE=$(sb_cmake_toolchain)"
  fi
}

# sb_is_ios -> true when the build product is meant to run on a device
sb_is_ios() { [ "$SB_TARGET" = ios-arm64 ] || [ "$SB_TARGET" = ios-arm64-sim ]; }
