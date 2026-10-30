# Targets: four operating systems, one file each

`manifest/tools.json` is the single source of truth. `tools/gen_manifest.py`
generates it, `scripts/matrix.py` turns it into the CI matrix, and
`recipes/_common.sh` maps a target name onto a compiler triple. Adding an
architecture is one table edit in three places, and none of them is a workflow.

```sh
python3 scripts/matrix.py --list-targets
python3 scripts/matrix.py --target windows-arm64 --pretty
python3 scripts/matrix.py --compose          # universal carriers
```

## The target table

| target | family | ABI | runner | what the file actually is |
|---|---|---|---|---|
| `linux-x86_64` | ELF | musl | ubuntu-24.04 | static ELF, zero `DT_NEEDED` |
| `linux-arm64` | ELF | musl | ubuntu-24.04-arm | same, aarch64 — the iOS sandbox guest and ARM servers |
| `linux-armv7` | ELF | musleabihf | ubuntu-24.04-arm | 32-bit ARM hard-float ELF |
| `linux-386` | ELF | musl | ubuntu-24.04 | 32-bit x86 ELF |
| `linux-riscv64` | ELF | musl | ubuntu-24.04 | LP64D ELF |
| `windows-x86_64` | PE | mingw-w64 | windows-2022 | PE32+, static CRT, imports only kernel32/msvcrt |
| `windows-arm64` | PE | mingw-w64 | windows-2022 | native ARM64 PE |
| `windows-386` | PE | mingw-w64 | windows-2022 | 32-bit PE |
| `macos-arm64` | Mach-O | macos | macos-14 | imports only the dyld shared cache |
| `macos-x86_64` | Mach-O | macos | macos-13 | Intel slice |
| `macos-universal` | Mach-O | macos | macos-14 | **fat carrier**, both slices, both payloads |
| `ios-arm64` | Mach-O | iphoneos | macos-14 | sandbox Mach-O, signed by the host app |
| `ios-arm64-sim` | Mach-O | iPhonesimulator | macos-14 | simulator slice |
| `windows-universal` | PE | mingw-w64 | windows-2022 | **one PE carrier** holding x86_64 and arm64 payloads |
| `linux-universal` | — | — | — | deliberately absent: see "what universal cannot mean" |

## What "static" means, per platform

There is no single definition, and pretending otherwise is how toolchain
bundles ship broken.

**ELF.** `readelf -d` must show no `DT_NEEDED` at all. With musl that is
achievable for almost everything, and it is the only form that runs inside an
iOS app sandbox (the iSH guest has no `/lib`), a scratch container, or an
initramfs.

**PE.** There is no such thing as a PE with zero imports; the loader always
resolves `kernel32.dll` and the CRT. The achievable property is: **no Visual C++
redistributable and no DLL beside the binary**. That means `/MT`-style static
CRT linking, which under mingw-w64 is `-static -static-libgcc
-static-libstdc++`, and under MSVC is `-MT` plus `/NODEFAULTLIB`.
`scripts/checkbin.py` enforces the import whitelist (kernel32, msvcrt, ntdll,
and the Win32 surface a compiler legitimately touches); anything else has to
come from inside the payload.

**Mach-O.** Darwin has no `libSystem.a` to link against — the kernel calls into
a shared cache that is not on disk. A "fully static iOS binary" is a category
error. The real property is **zero non-system imports**: every `LC_LOAD_DYLIB`
is under `/usr/lib`, `/System/Library`, or `@rpath/libswift*`, and the stub
driver enforces it.

**Scripts.** A bundle whose entry is a shell or Python script is not static at
all, and its manifest cell says so (`tier: layer`), because it needs the
interpreter it carries *and* a host that can execute it.

## Four tiers

| tier | meaning | example |
|---|---|---|
| `static` | one binary, zero non-system imports | `ninja`, `make`, `zig`, `busybox`, `jq` |
| `macho` | one Mach-O, dyld-cache imports only | `make` on iOS |
| `sfx` | carrier + blob region carrying a tree | `node` on Windows, `clang` on Windows |
| `layer` | `sfx` whose shared trees are content-addressed, shared across bundles on disk | `java`, `kotlin`, `python`, `swift` |

A `layer` bundle is what makes `java` + `kotlin` + `meson` cost one JRE and one
CPython instead of three, and what lets a clang bundle and a swift bundle share
one resource directory.

## What "universal" cannot mean

A file is loaded by one kernel, and that kernel reads one header format. You
can therefore build:

* **`macos-universal`** — a fat Mach-O, the format Apple's own `dyld` dispatches
  on. Both slices are real, both payloads are native, and one download runs on
  Apple Silicon and Intel. The carrier is `lipo`'d from the two stubs; the
  bundle carries an arm64 payload and an x86_64 payload, and the stub picks by
  the slice it is running as.
* **`windows-universal`** — one PE32+ carrier compiled for x86_64, which
  Windows on ARM runs under its x64 emulation layer. The stub there reads
  `PROCESSOR_ARCHITEW6432` (ARM64 when an x64 process sits on ARM hardware) and
  executes the *native* arm64 payload. The file is therefore universal in
  practice: native on x64, emulated boot then native payload on ARM64.

And you cannot build:

* **`linux-universal`** — `execve` on a foreign ELF returns `ENOEXEC`. Nothing
  in userspace can fix that. The honest answer is five files, or a shell script
  that picks by `uname -m`, and the manifest says so instead of shipping a
  bundle that lies.
* **one file across ELF/PE/Mach-O.** Polyglots exist; none of them survives
  code signing, and an iOS app will not launch a file whose header is a PE.

`scripts/compose.py` builds both universal carriers from the per-slice
artifacts — it never rebuilds, so the compose job costs seconds.

## How each language is built, per platform

The interesting part is not "does upstream ship a tarball"; it is which route
keeps the output static.

### C/C++ — clang/LLVM

* **ELF** — built from source with `LLVM_BUILD_LLVM_DYLIB=OFF` and
  `CLANG_LINK_CLANG_DYLIB=OFF`, so every shipped tool links the static archives
  and comes out with zero `DT_NEEDED`. The `lib/clang/<ver>` resource directory
  is a layer, shared with the swift bundle.
* **PE** — two routes: a mingw-w64 build with
  `-DLLVM_STATIC_LINK_CXX_STDLIB=ON` and `-static` link flags (fully static
  CRT), or the official `clang+llvm-*-pc-windows-msvc` release with the VC
  runtime carried inside the payload. Both are `tier: sfx`.
* **Mach-O** — the Xcode toolchain (or the darwin release). Everything it
  imports is in the dyld cache, so it is a one-file tool for the sandbox.
* **iOS** — clang runs *inside* the sandbox with an SDK layer: `-isysroot`
  points at the layer, linking goes through `ld64.lld`, and JIT is off unless
  the host app holds an entitlement.

### Swift

Swift's own story is the cleanest one in this repository: the **Static Linux
SDK** makes `swift build --swift-sdk aarch64-swift-linux-musl` emit a genuinely
static executable. So the bundle is `layer` (the compiler is glibc-linked) while
its *output* is `static`. On Windows the toolchain needs the MSVC linker and the
redistributable, which the payload carries. iOS is not a host: `swiftc` for iOS
lives in the `macos-*` bundle.

### Rust

`rustup`'s dist tarballs, installed with upstream's own `install.sh` so the
`rustlib` layout and target JSONs land where `rustc` expects them. Output is
made static by target choice, not by the compiler's own linkage:
`--target x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`, or
`RUSTFLAGS=-Ctarget-feature=+crt-static` on the Windows GNU triples.
`universal-apple-darwin` is one tarball with both Mac slices, which is why
`macos-universal` costs one rustc, not two.

### Go

The only toolchain here that is static by construction: `CGO_ENABLED=0`
produces a single file on every platform, and the payload is the GOROOT the
compiler needs. Official archives cover amd64, arm64, armv6l, 386, riscv64,
win-x64, win-arm64, darwin-*. There is no windows-386 Go host toolchain worth
shipping (upstream still publishes one; it is marked experimental).

### Zig

One tarball, one static binary, and — more importantly — the cross compiler the
rest of the repository uses: `zig cc -target aarch64-w64-mingw32` is how ELF
and PE artefacts get built on hosts that have no mingw installed.

### Python

Built from source with `*static*` rewritten over the generated
`Modules/Setup.stdlib`, which is the only way to link every extension module
into the interpreter (a static `python3` that cannot `dlopen` is a `python3`
that dies on `import ssl`). Windows is the exception: CPython's build system
assumes MSVC, so the Windows route is python-build-standalone rather than a
mingw cross build.

### Node

Upstream builds are glibc on Linux and a plain PE on Windows; the bundle is
`layer` and says so. The iOS slice is a `nodejs-mobile` build with
`--without-snapshot --with-intl=none`, because the sandbox forbids JIT.

### TypeScript, Meson

Both are scripts, not compilers: `tsc` is JavaScript on node, `meson` is Python.
Their bundles are the wheel/npm tree plus a `layer` reference to the runtime, so
a project that carries node + tsc stores node once.

### Java, Kotlin

A JVM is never a static binary — `libjvm.so` dlopens `libnio`, `libzip`, `libnet`
at startup. The honest bundle is a `jlink`'d runtime image (`java.base` +
`jdk.compiler` + `jdk.jdeps` + `zipfs`, ~90 MiB instead of ~330) as a layer, and
Kotlin's compiler jar rides on the identical layer. `jlink` emits a runtime only
for its own host, which is why `windows-arm64` needs an ARM runner.

### make, ninja

The two tools that really are one file everywhere: `make` from source with
`--host=$TRIPLE --without-guile` and `-static` (mingw gives a single PE),
`ninja` as 20 C++ files compiled directly with the cross compiler. On iOS both
run inside the sandbox and are what theos uses.

## Cost, roughly

| target | what it costs to build the whole catalog |
|---|---|
| `linux-x86_64`, `linux-arm64` | minutes for the release-based tools, hours for clang/swift |
| `linux-armv7`, `linux-386`, `linux-riscv64` | source builds only; the same hours as x86_64 |
| `windows-*` | release fetches + mingw source builds, minutes each |
| `macos-*` | release fetches + Xcode toolchain, minutes each |
| `ios-arm64` | no heavy compilers: the SDK comes from the macOS lane |

CI runs one job per cell with a 40-minute ceiling, `max-parallel: 8`.
