# staticbuild

One repository that turns compilers, SDKs and build tools into **one file each** — a file you drop into an iOS app, an iSH guest, or a CI job and run.

```
$ ./clang-20.1.8-linux-arm64 --version
clang version 20.1.8
$ ./theos-2024.11-ios-arm64 --sb-print-meta
{"tool":"theos","version":"2024.11","entry":"bin/theos","paths":["bin"],...}
```

The goal is not novelty. It is that a downstream project adds `ldid`, `dpkg-deb`, `make`, `clang` or `python3` by vendoring **one file with a sha256** instead of re-deriving a toolchain install — no `PATH` surgery, no `DYLD_LIBRARY_PATH`, no `/usr/lib`, no Homebrew, no system packages.

---

## Two platforms, two meanings of "static"

Pretending these are the same is how toolchain bundles ship broken. Every entry in the catalog is classified per target, and CI enforces the classification.

| Target family | Targets | The claim | Enforced by |
|---|---|---|---|
| **ELF** | `linux-arm64`, `linux-x86_64` | `readelf -d` prints **zero** `DT_NEEDED`. Runs on any aarch64 kernel, including the iOS sandbox guest and a bare initramfs. | `scripts/verify.sh` |
| **Mach-O** | `ios-arm64`, `macos-arm64` | `otool -L` lists only `/usr/lib/*`, `/System/Library/*`, `@rpath/libswift*` — the dyld shared cache. Nothing extra to embed in the app. | `scripts/verify.sh` |

On Darwin there is no `libSystem.a`; a "fully static iOS binary" is a category error. Zero non-system imports is the real, achievable property, and it is the one that shrinks an app bundle.

Four tiers, orthogonal to the family:

| Tier | What it physically is | Examples |
|---|---|---|
| `static` | One file, nothing else. | `ninja`, `make`, `jq`, `rg`, `ldid`, `dpkg-deb`, `busybox`, `xz`, `zstd`, `patchelf`, `qemu-*` |
| `macho` | One Mach-O importing only OS libraries. | `clang` (iOS), `ninja`, `make`, `curl` |
| `sfx` | 2.4 MB static stub + zstd payload that carries a tree (resource dir, stdlib, JRE), unpacked once into a content-addressed cache. | `clang`, `python`, `swift`, `java`, `node`, `theos`, `git` |
| `layer` | `sfx` whose shared trees are hash-addressed, so `java` + `kotlin` store **one** JRE and `python` + `meson` store **one** stdlib. | `java`, `kotlin`, `python`, `swift`, `llvm` |

---

## The catalog

Full list, versions, sizes and licences: [`manifest/tools.json`](manifest/tools.json).

**Compilers / toolchains** — `clang`/`llvm` (lld, clangd, clang-format, clang-tidy, llvm-*), `swift`, `rust`, `go`, `zig`
**Apple / jailbreak** — `theos` + `logos`, `ldid`, `dpkg` tooling, `xtool`
**Languages** — `python`, `node` (jitless on iOS), `typescript`, `java`, `kotlin`
**Build orchestration** — `cmake`, `ninja`, `make`, `meson`
**Packaging / binary tools** — `dpkg-deb`, `fakeroot`, `patchelf`, `zstd`, `xz`, `tar`, `openssl`, `ccache`, `protobuf`
**Core** — `busybox`, `git`, `curl`, `jq`, `ripgrep`
**Emulation** — `qemu-user-static`, `proot`

Not all of these can run *on* iOS. The catalog says so per target instead of quietly omitting them — `swiftc`, `rustc`, `go`, `zig`, the JVM and `xtool` are cross compilers, so their iOS story is a `macos-arm64` or `linux-arm64` bundle that emits iOS binaries. [`docs/caveats.md`](docs/caveats.md) has the full table with reasons.

### Status — what CI has actually produced

Green means: built, verified (tier, size budget, smoke run in a clean env) and uploaded as an artifact.

| target | green | written but not yet exercised by CI |
|---|---|---|
| `linux-arm64` | `busybox`, `jq`, `ldid`, `make`, `ninja`, `openssl`, `patchelf`, `ripgrep`, `xz`, `zstd` | `llvm`, `swift`, `rust`, `go`, `zig`, `python`, `node`, `typescript`, `java`, `kotlin`, `cmake`, `meson`, `dpkg`, `tar`, `curl`, `git`, `fakeroot`, `ccache`, `protobuf`, `qemu`, `proot`, `theos` |
| `ios-arm64` / `macos-arm64` | — | every recipe; the Mach-O path needs a macOS runner pass |

The green column is not a claim about the rest: those recipes are written, reviewed and shellcheck-clean, but a recipe that has never run is a recipe with a bug in it. The CI run for this repository is the honest source of truth — open Actions and read the matrix.

---

## Install

```sh
# 1. grab one file, verify it, run it
curl -fsSLO https://github.com/R0GUEEE/staticbuild/releases/latest/download/ldid-2.1.5-ios-arm64
sha256sum -c <<< "$(curl -fsSL .../SHA256SUMS | grep ldid)"
chmod +x ldid-2.1.5-ios-arm64
./ldid-2.1.5-ios-arm64
```

For downstream projects that need the *tree* (headers, stdlib, SDK) instead of the executable:

```sh
./clang-20.1.8-linux-arm64 --sb-extract-dir /opt/clang-20   # materialise, no exec
./clang-20.1.8-linux-arm64 --sb-print-meta                   # what it carries
./clang-20.1.8-linux-arm64 --sb-version                      # stub + payload digest
```

Inside a bundle, `SB_BUNDLE_ROOT` is the extraction directory, `PATH` already contains its `bin/`, and the runtime variables a tool expects (`GOROOT`, `JAVA_HOME`, `CMAKE_ROOT`, `THEOS`, `PYTHONHOME`) point inside it — never at the host.

---

## Build

```sh
make tools/ninja TARGET=linux-arm64      # one tool
make all TARGET=ios-arm64                # the catalog for a target
make matrix TARGET=linux-arm64           # what CI will run
make lint                                # manifest / shell / python checks
make verify                              # tier + budget + smoke, every artifact
```

Targets: `linux-arm64`, `linux-x86_64`, `ios-arm64`, `macos-arm64`.
CI builds ELF on `ubuntu-24.04-arm` inside Alpine, and Mach-O on `macos-14`; the matrix is generated from the manifest, so adding a tool never means editing a workflow.

---

## Repository layout

```
manifest/tools.json    single source of truth: id, version, tier, status, budget, smoke test
recipes/<id>.sh        one POSIX sh script per tool; $SB_VERSION comes from the manifest
recipes/_common.sh     sb_init, sb_fetch, sb_bin, sb_layer, sb_meta, sb_finish
stub/                  the 2.4 MB Go self-extractor (trailer, zstd payload, layers)
scripts/pack.py        deterministic tar + zstd + trailer
scripts/verify.sh      tier / leak / budget / smoke enforcement
scripts/matrix.py      manifest -> GitHub Actions matrix
docs/                  architecture, iOS integration, caveats, adding a tool
```

Format, layer mechanics and determinism: [`docs/architecture.md`](docs/architecture.md).
Embedding in an app: [`docs/ios.md`](docs/ios.md).

---

## Verifying a release

Every release carries `SHA256SUMS`, `SHA256SUMS.minisig`, an `index.json` (tool, version, target, size, sha256, url) and a per-bundle `provenance` record naming the recipe, the commit, the runner and the upstream tarball digest.

`verify.sh` re-derives the tier claim at build time, so a bundle that silently grows a `DT_NEEDED` or an `@rpath` dependency fails the build instead of the user's app.

## Licence

Build scripts: MIT. Bundled upstream components keep their own licences — each bundle carries them under `.sb/`, and [`docs/caveats.md`](docs/caveats.md) flags the ones (ldid AGPL, GPL tools, JDK, Xcode SDKs) whose terms you must read before redistributing commercially.
