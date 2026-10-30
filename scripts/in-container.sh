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
    build-base clang lld cmake ninja python3 py3-pip curl git zstd xz go file bash \
    binutils tar gzip bzip2 perl pkgconf make autoconf automake libtool patch \
    zlib-dev zstd-dev xz-dev bzip2-dev openssl-dev libmd-dev linux-headers \
    gettext-dev gettext-static libffi-dev libxml2-dev sqlite-dev ncurses-dev \
    readline-dev gdbm-dev
  # Static archives for the interpreter and the .deb tooling. Alpine ships them
  # as separate -static subpackages; a missing one must not fail the build,
  # because only that tool needs it.
  for p in zlib-static bzip2-static xz-static zstd-static openssl-static \
           ncurses-static readline-static sqlite-static libffi-static \
           gdbm-static libmd-static libxml2-static; do
    apk add --no-cache "$p" >/dev/null 2>&1 || true
  done
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential cmake ninja-build python3 curl git zstd xz-utils golang-go \
    file binutils tar gzip bzip2 perl pkg-config make autoconf automake libtool \
    patch ca-certificates unzip zip zlib1g-dev libzstd-dev liblzma-dev libbz2-dev \
    libssl-dev libmd-dev libffi-dev libxml2-dev libsqlite3-dev libncurses-dev \
    libreadline-dev libgdbm-dev gettext
  # Ubuntu 24.04 ships go 1.22 and 22.04 ships 1.18; the stub's go.mod asks for
  # 1.23, so take the toolchain from upstream rather than from the distro.
  if ! go version 2>/dev/null | grep -q 'go1\.2[3-9]'; then
    curl -fsSL --retry 3 -o /tmp/go.tgz https://go.dev/dl/go1.23.9.linux-arm64.tar.gz
    tar -C /usr/local -xzf /tmp/go.tgz
    PATH=/usr/local/go/bin:$PATH
    export PATH
  fi
fi

# The recipe header declares its own packages; the list above is the floor.
sh scripts/deps.sh "$id" || true

# The SFX stub is Go, CGO off, so it is static on either libc.
make stub

make "tools/$id" TARGET="$target" JOBS="$JOBS"
