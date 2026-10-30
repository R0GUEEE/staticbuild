#!/bin/sh
# deps: build-base cmake git
# protoc — needs abseil and utf8_range as siblings; the submodules are the whole
# recipe. Well-known types ship in include/ so `--proto_path` works offline.
. "$(dirname "$0")/_common.sh"
sb_init

if [ ! -d "$SB_WORK/src/protobuf/.git" ]; then
  git clone --depth 1 --branch "v$SB_VERSION" --recurse-submodules --shallow-submodules \
    https://github.com/protocolbuffers/protobuf.git "$SB_WORK/src/protobuf"
fi
cd "$SB_WORK/src/protobuf"

cmake -B out -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_BUILD_CONFORMANCE=OFF \
  -Dprotobuf_BUILD_EXAMPLES=OFF \
  -Dprotobuf_ABSL_PROVIDER=module \
  -DCMAKE_CXX_FLAGS="$(sb_cflags)" \
  -DCMAKE_EXE_LINKER_FLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build out -j "$SB_JOBS" --target protoc

sb_bin out/protoc protoc
mkdir -p "$SB_STAGE/include"
cp -R src/google "$SB_STAGE/include/"
SB_PATHS="bin"
SB_ENTRY="bin/protoc"
sb_finish
