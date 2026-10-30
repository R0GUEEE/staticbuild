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

## Four platforms, three meanings of "static"

The catalog covers Linux (5 architectures), Windows (3), macOS (2 plus a fat
universal carrier) and iOS (device and simulator). Pretending one definition of
"static" covers all of them is how toolchain bundles ship broken, so the
definition is per family and CI enforces each one:

| family | the claim | enforced by |
|---|---|---|
| **ELF** (`linux-*`) | `readelf -d` prints **zero** `DT_NEEDED`. Runs on any kernel of that arch: the iOS sandbox guest, a scratch container, an initramfs. | `scripts/verify.py` |
| **PE** (`windows-*`) | PE32+ whose imports are only the Win32 surface (`kernel32`, `msvcrt`, ...): static CRT, **no Visual C++ redistributable, no DLL beside the binary**. | `scripts/checkbin.py` |
| **Mach-O** (`macos-*`, `ios-*`) | every `LC_LOAD_DYLIB` is under `/usr/lib`, `/System/Library` or `@rpath/libswift*` — the dyld shared cache. There is no `libSystem.a`; "fully static iOS binary" is a category error, zero non-system imports is the real property. | `scripts/verify.py` |

[`docs/targets.md`](docs/targets.md) has the full target table, the per-language
build route for each platform, and what universal can and cannot mean.

### Universal, honestly

| carrier | what it is | why it works |
|---|---|---|
| `macos-universal` | fat Mach-O, arm64 + x86_64 slices, each slice carrying its own native payload | `dyld` picks the slice |
| `windows-universal` | one x86_64 PE that also carries the arm64 payload | Windows on ARM runs x64 binaries under emulation; the stub reads `PROCESSOR_ARCHITEW6432` and execs the **native** arm64 tree |
| `linux-universal` | **not a thing** — `execve` on a foreign ELF returns `ENOEXEC` | five per-arch files, or a script that picks by `uname -m` |

One file, one kernel, one header format. The manifest says so rather than
shipping a bundle that lies.

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

The green column is not a claim about the rest. `ga` means built, verified and
exercised by CI on that target; `experimental` means the recipe has a branch for
it and it compiles, but it is not covered by the green matrix; `planned` means
the approach is documented and the recipe branch is not written;
`not-supported` means it is physically or upstream impossible, with the reason
in the manifest.

```sh
python3 scripts/matrix.py --list-targets        # cells per target
python3 scripts/matrix.py --target windows-arm64 --pretty
python3 scripts/matrix.py --check               # manifest ↔ recipes consistency
```

Every cell in `manifest/tools.json` carries its tier, entry point, smoke
command, size budget and status. The honest source of truth is the Actions tab:
open a run and read the matrix.

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
