#!/bin/sh
# deps: build-base cmake ninja python3 zlib-dev
# Clang / LLVM, fully static: one ELF per tool, zero DT_NEEDED.
#
# The four flags that decide whether this ships a static binary or a bundle of
# .so lookalikes:
#   CLANG_LINK_CLANG_DYLIB=OFF   clang links the static libclang*.a set
#   LLVM_BUILD_LLVM_DYLIB=OFF    no libLLVM.so is produced at all
#   LLVM_LINK_LLVM_DYLIB=OFF     nothing is allowed to prefer one if it exists
#   LLVM_STATIC_LINK_CXX_STDLIB=ON  libstdc++ comes in too
#
# Scope: clang + lld + the object/binary utilities a build actually calls.
# clang-tools-extra (clangd, clang-tidy) is a separate ~40% build time and is
# off by default; SB_LLVM_EXTRA=1 turns it back on.
. "$(dirname "$0")/_common.sh"
sb_init

_projects="clang;lld"
[ "${SB_LLVM_EXTRA:-0}" = 1 ] && _projects="clang;lld;clang-tools-extra"

src=$(sb_fetch "https://github.com/llvm/llvm-project/releases/download/llvmorg-$SB_VERSION/llvm-project-$SB_VERSION.src.tar.xz")
sb_unpack "$src" "$SB_WORK/src/llvm"
# The release asset unpacks to llvm-project-<version>.src, not llvm-project-<version>.
_src=$(find "$SB_WORK/src/llvm" -maxdepth 1 -mindepth 1 -type d -name 'llvm-project-*' | head -1)
[ -n "$_src" ] && [ -d "$_src/llvm" ] || die "llvm: unexpected tarball layout"

_common="-G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_ENABLE_PROJECTS=$_projects
  -DLLVM_TARGETS_TO_BUILD=AArch64;X86;RISCV
  -DLLVM_BUILD_LLVM_DYLIB=OFF
  -DLLVM_LINK_LLVM_DYLIB=OFF
  -DCLANG_LINK_CLANG_DYLIB=OFF
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DLLVM_INSTALL_UTILS=ON
  -DCLANG_DEFAULT_LINKER=lld
  -DLLVM_PARALLEL_LINK_JOBS=1"

case "$SB_FAMILY" in
  elf)
    cmake -S "$_src/llvm" -B "$SB_WORK/llvm-out" $_common \
      -DCMAKE_C_FLAGS="-O2" -DCMAKE_CXX_FLAGS="-O2" \
      -DCMAKE_EXE_LINKER_FLAGS="-static" \
      -DLLVM_STATIC_LINK_CXX_STDLIB=ON || die "llvm: configure failed"
    ;;
  macho)
    _sdk=$(xcrun --sdk "${SB_SDK:-iphoneos}" --show-sdk-path)
    cmake -S "$_src/llvm" -B "$SB_WORK/llvm-out" $_common \
      -DCMAKE_OSX_ARCHITECTURES="$SB_ARCH" \
      -DCMAKE_OSX_SYSROOT="$_sdk" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${SB_MIN_OS:-15.0}" \
      -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
      -DRUNTIMES_CMAKE_ARGS="-DCMAKE_OSX_SYSROOT=$_sdk;-DCMAKE_OSX_ARCHITECTURES=$SB_ARCH;-DLIBCXX_ENABLE_SHARED=OFF;-DLIBCXXABI_ENABLE_SHARED=OFF;-DLIBUNWIND_ENABLE_SHARED=OFF" \
      -DLLVM_ENABLE_LIBCXX=ON || die "llvm: configure failed"
    ;;
esac

log "building clang + lld ($SB_JOBS jobs, this is the long one)"
cmake --build "$SB_WORK/llvm-out" -j "$SB_JOBS" || die "llvm: build failed"

_p="$SB_WORK/llvm-out"
mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib/clang"

# One copy of clang, then symlinks: clang and clang++ are the same 150 MiB
# binary and a static build makes that copy very visible in the artifact size.
for t in clang clang-format lld llvm-ar llvm-ranlib llvm-nm llvm-strip \
         llvm-objcopy llvm-readelf llvm-objdump llvm-size llvm-profdata \
         llvm-install-name-tool llvm-otool llvm-lipo; do
  [ -x "$_p/bin/$t" ] && sb_bin "$_p/bin/$t" "$t"
done
[ -e "$SB_STAGE/bin/clang" ] || die "llvm: clang was not produced"
ln -sf clang "$SB_STAGE/bin/clang++"
ln -sf clang "$SB_STAGE/bin/clang-cpp"
[ -e "$SB_STAGE/bin/lld" ] && ln -sf lld "$SB_STAGE/bin/ld.lld"

# clang's resource dir: builtin headers and the compiler-rt builtins clang links
# into every iOS/Mach-O output. Without it clang starts and then fails on
# <stdint.h>, which reads like a broken toolchain.
_ver=$(sed -n 's/^set(LLVM_VERSION_MAJOR \([0-9]*\))/\1/p' "$_src/llvm/CMakeLists.txt" | head -1)
if [ -d "$_p/lib/clang" ]; then
  cp -R "$_p/lib/clang/." "$SB_STAGE/lib/clang/"
else
  warn "no lib/clang resource dir in the build tree"
fi
[ -d "$SB_STAGE/lib/clang/$_ver" ] || warn "resource dir does not match clang $_ver"

# Fail here rather than ship a bundle that silently wants libLLVM.so.20.
for b in "$SB_STAGE/bin"/*; do
  [ -f "$b" ] || continue          # symlinks were copied as their target
  case "$(file -b "$b")" in
    *ELF*) readelf -d "$b" 2>/dev/null | grep -q NEEDED && die "$(basename "$b") is dynamically linked" ;;
    *Mach-O*) otool -L "$b" | tail -n +2 | grep -qvE '/usr/lib/|/System/Library/|@rpath/libswift' && \
      die "$(basename "$b") imports a non-system dylib" ;;
  esac
done

export SB_PATHS="bin"
export SB_ENTRY="bin/clang"
export SB_ENV='"CC": "${ROOT}/bin/clang", "CXX": "${ROOT}/bin/clang++"'
sb_layer lib
sb_finish
