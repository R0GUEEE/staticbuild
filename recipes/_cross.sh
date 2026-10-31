#!/bin/sh
# shellcheck shell=sh
# iOS / macOS cross-compilation layer. Sourced by _common.sh for every target,
# active only for macho ones.
#
# The problem it solves, in one sentence: on a macOS runner an ios-arm64 build is
# a cross build between two identical machines, so every autoconf and cmake
# project compiles a test program, tries to run it, gets EPERM because the
# Mach-O is platform iOS, and aborts with "cannot run C compiled programs".
#
# Three parts, all required:
#   1. compiler wrappers carrying -arch/-isysroot/deployment target, exported as
#      CC/CXX/AR/..., because plenty of builds ignore CFLAGS;
#   2. --build/--host on configure, which is what makes autoconf skip its run
#      tests instead of failing them;
#   3. a cmake toolchain file, because cmake refuses to cross-compile at all
#      without CMAKE_SYSTEM_NAME and then also stops try_run().

sb_ios_sdk() {
  _s=${IOS_SDK_PATH:-}
  [ -n "$_s" ] || _s=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
  [ -n "$_s" ] || die "no iPhoneOS SDK: xcrun --sdk iphoneos --show-sdk-path is empty"
  printf '%s\n' "$_s"
}

sb_macos_sdk() {
  _s=${MACOS_SDK_PATH:-}
  [ -n "$_s" ] || _s=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
  [ -n "$_s" ] || die "no macOS SDK: xcrun --sdk macosx --show-sdk-path is empty"
  printf '%s\n' "$_s"
}

# sb_macho_lane -> "flags|xcrun-sdk|cmake-system-name|sysroot"
sb_macho_lane() {
  case "$SB_TARGET" in
    ios-arm64)
      _s=$(sb_ios_sdk)
      printf '%s|%s|%s|%s\n' \
        "-arch $SB_ARCH -isysroot $_s -miphoneos-version-min=${SB_MIN_OS:-15.0}" \
        iphoneos iOS "$_s" ;;
    ios-arm64-sim)
      _s=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
      printf '%s|%s|%s|%s\n' \
        "-arch $SB_ARCH -isysroot $_s -mios-simulator-version-min=${SB_MIN_OS:-15.0}" \
        iphonesimulator iOS "$_s" ;;
    macos-*)
      _s=$(sb_macos_sdk)
      printf '%s|%s|%s|%s\n' \
        "-arch $SB_ARCH -isysroot $_s -mmacosx-version-min=${SB_MIN_OS:-11.0}" \
        macosx macOS "$_s" ;;
    *) die "sb_macho_lane: $SB_TARGET is not a macho target" ;;
  esac
}

# sb_macho_toolchain -> writes $SB_WORK/bin/sb-{cc,cxx,ar,...}. Idempotent.
sb_macho_toolchain() {
  [ "$(uname -s)" = Darwin ] || return 0
  _bin=$SB_WORK/bin
  mkdir -p "$_bin"
  _lane=$(sb_macho_lane)
  _flags=$(printf '%s' "$_lane" | cut -d'|' -f1)
  _sdkflag=$(printf '%s' "$_lane" | cut -d'|' -f2)

  # A wrapper, not a CC string with spaces: many Makefiles quote CC as one word
  # and "xcrun -sdk iphoneos clang" then fails with "-sdk: command not found".
  for _pair in "cc:clang" "cxx:clang++" "ar:ar" "ranlib:ranlib" "strip:strip" \
               "nm:nm" "ld:ld" "lipo:lipo" "otool:otool" \
               "install_name_tool:install_name_tool"; do
    _name=${_pair%%:*}
    _tool=${_pair#*:}
    case "$_tool" in
      clang|clang++) _f=" $_flags" ;;
      *)             _f="" ;;
    esac
    printf '#!/bin/sh\nexec xcrun --sdk %s %s%s "$@"\n' "$_sdkflag" "$_tool" "$_f" \
      > "$_bin/sb-$_name"
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
  # Old config.sub (GNU make 4.4.1 ships 2018) does not know
  # arm64-apple-ios-simulator and aborts with "config.sub ... failed". The
  # simulator distinction is carried by -isysroot and -mios-simulator-version-min
  # in the wrapper flags, not by the host triple, so autoconf gets the device
  # triple and still treats the build as a cross build.
  case "$SB_TARGET" in
    *-sim) SB_HOST_TRIPLE=${SB_TRIPLE%-simulator} ;;
    *)     SB_HOST_TRIPLE=$SB_TRIPLE ;;
  esac
  SB_BUILD_TRIPLE=$(uname -m)-apple-darwin
  export SB_HOST_TRIPLE SB_BUILD_TRIPLE
}

# sb_configure ARGS... -> ./configure carrying the cross identity.
sb_configure() {
  if [ "$SB_FAMILY" = macho ] && [ "$(uname -s)" = Darwin ]; then
    [ -n "${SB_BUILD_TRIPLE:-}" ] || sb_macho_toolchain
    # config.sub shipped with most projects predates arm64-apple-ios-simulator
    # and rejects it outright ("failed"). Autoconf only needs to know it is
    # cross-compiling and that the platform is Darwin-ish; the SDK, arch and
    # deployment target all come from the compiler wrapper.
    _host=$SB_HOST_TRIPLE
    case "$_host" in
      *-apple-ios-simulator) _host=arm64-apple-ios ;;
    esac
    log "configure --build=$SB_BUILD_TRIPLE --host=$_host"
    ./configure --build="$SB_BUILD_TRIPLE" --host="$_host" "$@"
  else
    ./configure "$@"
  fi
}

# sb_cmake_toolchain -> writes and prints the cmake toolchain file.
sb_cmake_toolchain() {
  _lane=$(sb_macho_lane)
  _system=$(printf '%s' "$_lane" | cut -d'|' -f3)
  _sysroot=$(printf '%s' "$_lane" | cut -d'|' -f4)
  _f=$SB_WORK/macho-toolchain-$SB_TARGET.cmake
  if [ -f "$_f" ]; then printf '%s\n' "$_f"; return 0; fi
  mkdir -p "$SB_WORK"
  {
    printf 'set(CMAKE_SYSTEM_NAME %s)\n' "$_system"
    printf 'set(CMAKE_SYSTEM_PROCESSOR %s)\n' "$SB_ARCH"
    printf 'set(CMAKE_OSX_ARCHITECTURES %s)\n' "$SB_ARCH"
    printf 'set(CMAKE_OSX_DEPLOYMENT_TARGET %s)\n' "${SB_MIN_OS:-15.0}"
    printf 'set(CMAKE_OSX_SYSROOT %s)\n' "$_sysroot"
    printf 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\n'
    printf 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)\n'
    printf 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)\n'
    # cmake compiles probe programs and refuses a cross build whose probes cannot
    # run; a static-library probe needs no execution at all.
    printf 'set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)\n'
    # iOS defaults every add_executable() to a MACOSX_BUNDLE, and projects that
    # install their executable then die with "install TARGETS given no BUNDLE
    # DESTINATION". Our binaries are posix_spawn'd, not SpringBoard-launched.
    printf 'set(CMAKE_MACOSX_BUNDLE OFF CACHE BOOL "" FORCE)\n'
  } > "$_f"
  printf '%s\n' "$_f"
}

# sb_cmake_args -> flags every cmake invocation needs on a macho target.
sb_cmake_args() {
  [ "$SB_FAMILY" = macho ] || return 0
  printf '%s\n' "-DCMAKE_TOOLCHAIN_FILE=$(sb_cmake_toolchain)"
  # Homebrew's cmake is 4.x and refuses projects whose cmake_minimum_required()
  # predates 3.5 (GNU tar still says 2.8.12). This raises the policy floor only.
  printf '%s\n' "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
  # check_function_exists() only compiles, and a C99 compiler happily accepts an
  # implicit declaration, so every function the SDK lacks (futimesat on iOS) is
  # reported present and the build fails later in the real file. Making implicit
  # declarations an error is what makes those probes answer honestly.
  printf '%s\n' "-DCMAKE_REQUIRED_FLAGS=-Werror=implicit-function-declaration"
}

sb_is_ios() { [ "$SB_OS" = ios ]; }
