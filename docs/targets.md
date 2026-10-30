# Targets

Every artefact in this repository is one file for one (os, arch) pair — with one
exception family, the *universal* files, which carry several payloads in one
carrier. This page is the map.

`scripts/matrix.py --list-targets` prints the live table with per-target tool
counts; `manifest/tools.json` is the machine-readable version.

## The table

| target | family | what "static" means here |
|---|---|---|
| `linux-x86_64` | ELF | `readelf -d` reports **zero** `DT_NEEDED`; runs on any x86_64 kernel, in a bare initramfs, or inside the iOS guest |
| `linux-arm64` | ELF | same, aarch64: ARM servers, Apple Silicon VMs, the iSH sandbox |
| `linux-armv7` | ELF | static EABI-hardfloat; 32-bit ARM boards, older Android-era kernels |
| `linux-386` | ELF | static 32-bit x86 |
| `linux-riscv64` | ELF | static LP64D riscv64 |
| `windows-x86_64` | PE | PE32+ importing **only** kernel32/msvcrt — static CRT, no `vcruntime140.dll` beside it |
| `windows-arm64` | PE | native Windows on ARM |
| `windows-386` | PE | 32-bit PE for legacy hosts |
| `macos-arm64` / `macos-x86_64` | Mach-O | imports only the dyld shared cache (`/usr/lib`, `/System/Library`) |
| `ios-arm64` / `ios-arm64-sim` | Mach-O | same rule; the enclosing app signs the binary |
| `macos-universal` | fat Mach-O | one file, `arm64` + `x86_64` slices, each with its own payload |
| `windows-universal` | PE | one x86_64 carrier that also carries the arm64 payload |
| `linux-universal` | — | **does not exist**, by physics (see below) |

## Why "static" is three different claims

Darwin has no `libSystem.a`: a fully static iOS binary is a category error. What
is achievable is *zero non-system imports*, which is the property that actually
shrinks an app bundle and keeps a tool running in a sandbox. Windows has a
static CRT but always imports `kernel32`; the claim there is "no redistributable
beside the binary". Linux is the only family where the literal claim — no
dynamic loader at all — is both possible and enforced.

`scripts/verify.py` enforces the claim per family by parsing the binary itself
(ELF `.dynamic`, PE import table, Mach-O load commands), so a Linux runner can
hold a `windows-arm64` payload to its claim without executing it.

## Universal files, honestly

A single file cannot be *executed* by both Linux and Windows: the loader reads
the header at offset 0. So "universal" is defined per platform family, and the
container supports two mechanisms:

**Fat carrier (macOS).** `lipo` joins the arm64 and x86_64 stub slices into one
Mach-O. `dyld` picks the slice, and each slice runs the payload for its own
architecture. One download, native on both, no Rosetta.

**Emulation-aware carrier (Windows).** The carrier is a single x86_64 PE, which
runs natively on x64 and under emulation on ARM64 Windows. Under emulation the
stub reads `PROCESSOR_ARCHITEW6432`, sees `ARM64`, and runs the *native* arm64
payload instead of the emulated x86_64 one. The user gets native speed; the
carrier stays one file.

**Linux** gets no universal file. The kernel `execve`s the carrier's own ELF
header; an `x86_64` carrier cannot run on `aarch64`. The manifest lists
`linux-universal` as `not-supported` with that reason instead of quietly
omitting it. Ship the per-arch files, or a launcher that picks.

In every case the packer stores identical files **once**: a universal bundle is
smaller than the sum of its slices, because the blob region is keyed by content
digest across payloads.

## Cross-compilation, per tool

Not every tool can run on every target, and the manifest says so per cell.
Three shapes recur:

* **Native everywhere** — `go`, `zig`, `make`, `ninja`, `ldid`, `busybox`: an
  upstream build exists per platform, or the source builds with a cross cc.
* **Host tool that emits another platform's binaries** — `swift`, `rust`,
  `clang` for iOS: the bundle is `macos-*`, and `-target arm64-apple-ios` is the
  flag that matters. The `ios-*` cells say `not-supported` with that reason.
* **Runtime that cannot exist on a platform** — `java`, `kotlin` on iOS (no JVM,
  JIT forbidden), `theos` on Windows (a POSIX-shell build system). Marked
  `not-supported` with the reason rather than `planned`.

## Adding a target

1. Add a row to `TARGETS` in `tools/gen_manifest.py` (os, arch, goos/goarch,
   family, runner, meaning).
2. Add a case to the table in `recipes/_common.sh` (arch, triple, family).
3. Add a row to `ALL` in `scripts/stub-build.sh` if the stub can be built for it.
4. `python3 tools/gen_manifest.py && python3 scripts/matrix.py --check`.

Tools that do not know the new target get `planned` automatically, with a reason,
so the matrix never silently skips a cell.
