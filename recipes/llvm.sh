#!/bin/sh
# deps: build-base cmake ninja python3 zlib-dev zstd-dev libxml2-dev
# Clang / LLVM 20, everything statically linked into each tool.
#
# Notes that cost hours to rediscover:
#  * CLANG_LINK_CLANG_DYLIB=OFF is what keeps libclang-cpp out of the picture;
#    with it ON, clang links libclang-cpp.so and the bundle stops being static.
#  * On iOS there is no libc++.a in the SDK, so the recipe builds LLVM's own
#    runtimes first (libc++/libc++abi/libunwind, static) and points clang at them.
#  * LLVM_ENABLE_PROJECTS is limited to the tools this repo ships; every extra
#    project is ~200 MiB of build.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/llvm/llvm-project/releases/download/llvmorg-$SB_VERSION/llvm-project-$SB_VERSION.src.tar.xz")
sb_unpack "$src" "$SB_WORK/src/llvm"
_src="$SB_WORK/src/llvm/llvm-project-$SB_VERSION"

_common="-G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_ENABLE_PROJECTS=clang;lld;clang-tools-extra
  -DLLVM_TARGETS_TO_BUILD=AArch64;ARM;X86;RISCV
  -DLLVM_BUILD_LLVM_DYLIB=OFF
  -DLLVM_LINK_LLVM_DYLIB=OFF
  -DCLANG_LINK_CLANG_DYLIB=OFF
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_LIBCXX=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INSTALL_UTILS=ON
  -DCLANG_DEFAULT_LINKER=lld
  -DLLVM_PARALLEL_COMPILE_JOBS=$SB_JOBS
  -DLLVM_PARALLEL_LINK_JOBS=2"

case "$SB_FAMILY" in
  elf)
    cmake -S "$_src/llvm" -B "$SB_WORK/llvm-out" $_common \
      -DCMAKE_C_FLAGS="-O2" -DCMAKE_CXX_FLAGS="-O2" \
      -DCMAKE_EXE_LINKER_FLAGS="-static" \
      -DLLVM_STATIC_LINK_CXX_STDLIB=ON
    ;;
  macho)
    _sdk=$(xcrun --sdk "${SB_SDK:-iphoneos}" --show-sdk-path)
    cmake -S "$_src/llvm" -B "$SB_WORK/llvm-out" $_common \
      -DCMAKE_OSX_ARCHITECTURES="$SB_ARCH" \
      -DCMAKE_OSX_SYSROOT="$_sdk" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${SB_MIN_OS:-15.0}" \
      -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
      -DRUNTIMES_CMAKE_ARGS="-DCMAKE_OSX_SYSROOT=$_sdk;-DCMAKE_OSX_ARCHITECTURES=$SB_ARCH;-DLIBCXX_ENABLE_SHARED=OFF;-DLIBCXXABI_ENABLE_SHARED=OFF;-DLIBUNWIND_ENABLE_SHARED=OFF" \
      -DLLVM_ENABLE_LIBCXX=ON
    ;;
esac

cmake --build "$SB_WORK/llvm-out" -j "$SB_JOBS"

_p="$SB_WORK/llvm-out"
mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib/clang" "$SB_STAGE/share"

for t in clang clang++ clang-format clang-tidy clangd lld ld.lld llvm-ar llvm-ranlib \
         llvm-nm llvm-objcopy llvm-readelf llvm-objdump llvm-strip llvm-size \
         llvm-install-name-tool llvm-otool llvm-lipo llvm-codesign llvm-profdata llvm-cov; do
  [ -x "$_p/bin/$t" ] && sb_bin "$_p/bin/$t" "$t"
done

# clang resource dir: builtin headers + compiler-rt builtins for the host triple
if [ -d "$_p/lib/clang" ]; then
  cp -R "$_p/lib/clang/." "$SB_STAGE/lib/clang/"
fi

# clangd needs clang-tidy's clang-check plugin data on some builds; harmless if absent
mkdir -p "$SB_STAGE/share/clang"
cp -R "$_p/share/clang/." "$SB_STAGE/share/clang/" 2>/dev/null || true

# Fail the build instead of shipping a bundle that silently wants libLLVM.so.20.1
for b in "$SB_STAGE/bin"/*; do
  case "$(file -b "$b")" in
    *ELF*) readelf -d "$b" 2>/dev/null | grep -q NEEDED && die "$(basename "$b") is dynamically linked" ;;
    *Mach-O*) otool -L "$b" | tail -n +2 | grep -qvE '/usr/lib/|/System/Library/' && \
      die "$(basename "$b") imports a non-system dylib" ;;
  esac
done

export SB_PATHS="bin"
export SB_ENTRY="bin/clang"
export SB_ENV='"CC": "${ROOT}/bin/clang", "CXX": "${ROOT}/bin/clang++"'
sb_layer lib
sb_finish
