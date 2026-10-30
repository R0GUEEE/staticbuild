#!/bin/sh
# Everything that has to happen *inside* the build container.
#
#   sh scripts/in-container.sh <tool-id> <target>
#
# Called by .github/workflows/build.yml under `docker run`. The container is
# alpine by default (musl, static ELF) and ubuntu when a recipe ships upstream
# binaries that are glibc-only (swift, java, node, kotlin, typescript). Both
# package managers are handled here so the workflow stays one step.
set -eu

id=${1:?tool id}
target=${2:?target}
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2)

if command -v apk >/dev/null 2>&1; then
  apk add --no-cache \
    build-base clang lld cmake ninja python3 py3-pip curl git zstd xz go file \
    binutils tar gzip bzip2 perl pkgconf make autoconf automake libtool patch \
    zlib-dev zstd-dev xz-dev bzip2-dev openssl-dev libmd-dev linux-headers \
    gettext-dev gettext-static libffi-dev libxml2-dev sqlite-dev ncurses-dev \
    readline-dev gdbm-dev
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential cmake ninja-build python3 curl git zstd xz-utils golang-go \
    file binutils tar gzip bzip2 perl pkg-config make autoconf automake libtool \
    patch ca-certificates unzip zip zlib1g-dev libzstd-dev liblzma-dev libbz2-dev \
    libssl-dev libmd-dev libffi-dev libxml2-dev libsqlite3-dev libncurses-dev \
    libreadline-dev libgdbm-dev gettext
fi

# The recipe header declares its own packages; the list above is the floor.
sh scripts/deps.sh "$id" || true

# The SFX stub is Go, CGO off, so it is static on either libc.
make stub

make "tools/$id" TARGET="$target" JOBS="$JOBS"
