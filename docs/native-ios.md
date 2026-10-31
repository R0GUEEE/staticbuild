# The native iOS toolchain: what actually runs on the phone

This page answers one question per tool: **can this be an iOS binary, and if
not, what is the honest alternative?** It is deliberately separated from the
aspirational status in the manifest, because "planned" hides four very different
reasons and the operator of this repository needs to know which one applies to
the tool they are about to rely on.

Two definitions first, because they get conflated constantly:

* **on-device** — a Mach-O arm64 binary, `platform IOS`, importing only
  dyld-shared-cache libraries, that a sandboxed app can `posix_spawn`. It needs
  no host, no jailbreak and no network.
* **host** — a tool that only makes sense on a Mac or a server: it *produces*
  iOS artifacts. Shipping it as an iOS binary would be a lie with a download
  button, which is the one thing this repository refuses to do.

## Column 1 — on device, and building today

| tool | artifact | notes |
|---|---|---|
| `ninja` | `ios-arm64`, `ios-arm64-sim` | cmake, `-G Unix Makefiles`, no Darwin-specific code. Green. |
| `zstd` | `ios-arm64` | plain C, static. Green. |
| `xz` | `ios-arm64` | autoconf with the cross identity (`--host=arm64-apple-ios`). Green. |
| `jq` | `ios-arm64` | oniguruma linked in, `-static` replaced by `-Wl,-dead_strip`. Green. |
| `ripgrep` | `ios-arm64` | `cargo --target aarch64-apple-ios`, rust-std installed by `rustup target add`. Green. |
| `make` | `ios-arm64` | GNU make 4.4.1; the recipe supplies `<ar.h>`, which the iPhoneOS SDK omits. |
| `ldid` | `ios-arm64` | Procursus fork, libplist + libcrypto (`ios64-cross`) statically linked. This is the signer every other on-device tool needs. |
| `dpkg` | `ios-arm64` | `dpkg-deb`, `dpkg-split`, `dpkg-query` only: no maintainer scripts, no root database. |
| `theos` | `ios-arm64` | makefiles + Logos (perl) + the `nic`/`logify` scripts; declares `clang make ldid` as requirements rather than pretending to bundle them. |
| `meson` | `ios-arm64` | pure Python; runs on the `python` bundle. |
| `python` | `ios-arm64` | CPython with every extension linked in (a sandboxed binary cannot `dlopen` a `.so` from its own tree on a signed device). |
| `node` | `ios-arm64` | built jitless from nodejs-mobile sources; stock Node needs executable memory, which iOS forbids. |
| `typescript` | `ios-arm64` | `tsc` as a JS bundle executed by the `node` bundle; Node's single-executable-application path is used where the platform allows it. |
| `llvm` / `clang` | `ios-arm64` | clang + lld + object utilities, `LLVM_TARGETS_TO_BUILD=AArch64`, resource dir shipped as a layer. This is the long build (1–3 h on a runner). |
| `busybox` | `ios-arm64` | applets as one binary; a few applets are disabled on Darwin where the syscall surface does not exist. |
| `tar` | `ios-arm64` | bsdtar/libarchive, since the iOS SDK ships libarchive's own codecs except crypto and zstd. |
| `curl`, `git`, `openssl`, `zstd`, `cmake`, `ccache`, `protobuf` | varies | all build as Mach-O; `git` needs `NO_MMAP`/`NO_GETTEXT` and is the largest of the C tools. |

## Column 2 — on device, but through a runtime, not a native compiler

| tool | route | why not a plain binary |
|---|---|---|
| `java` (`javac`, `jar`) | OpenJDK **Zero** (C++ interpreter, no JIT) compiled for `ios-arm64` | iOS forbids `mprotect(PROT_EXEC)`, so HotSpot's C1/C2 cannot exist. Zero is the only JVM that can work, and it is 10–30× slower; it is a research build, not a shipped artifact today. |
| `kotlin` (`kotlinc`) | runs on the JVM above | kotlinc is a JVM application; its feasibility is exactly the JVM's feasibility. Kotlin/Native is a *producer* target, not a host. |

## Column 3 — host only, and why that is not a gap to be closed

| tool | why an iOS binary is not a thing |
|---|---|
| `swift` (`swiftc`) | Apple ships swift-frontend only in Xcode for macOS; the open-source toolchain does not support `aarch64-apple-ios` as a **host**. The stdlib cross-compiles to iOS, the compiler does not run there. Deliverable is the `macos-arm64` bundle: `swiftc` on a Mac that emits `ios-arm64` products. |
| `rust` (`rustc`, `cargo`) | `aarch64-apple-ios` is a *target triple*; rustc has no iOS host. The `macos-arm64`/`linux` bundles cross-compile to `aarch64-apple-ios`, and the `ripgrep` row above is the proof that the target works. |
| `go` | `GOOS=ios GOARCH=arm64` is a supported **target**; the go command is not published for iOS. On-device Go work goes through the `linux-arm64` bundle inside an iSH/LinuxKit guest, or through `macos-arm64` on a Mac. |
| `zig` | Zig ships `aarch64-macos`/`x86_64-linux` builds. It *targets* `aarch64-ios` fine (and is used here as a `cc` for cross builds), but Zig itself as an iOS binary is unsupported upstream. |
| `xtool` | drives `xcodebuild`-adjacent tooling on macOS by design. |

If you want a Swift or Rust toolchain **in your pocket**, the answer is a
`linux-arm64` bundle running in an iSH guest, or the `macos-arm64` bundle
driving a Mac over SSH. Both are shipped here. Neither is pretending to be
something an iPhone kernel will load.

## How a bundle reaches the device

1. CI builds `dist/<tool>-<version>-<target>`; `scripts/verify.py` asserts
   format, platform (`LC_BUILD_VERSION` = 2 for iOS, 7 for the simulator),
   deployment target, import set and size budget.
2. The file is a single executable: carrier stub + zstd blob region +
   content-addressed index. Copying it into an app bundle is the whole install;
   no extraction step, no `$HOME` assumption.
3. The host app signs it with its own identity. On a jailbroken device, re-sign
   with the `ldid` bundle: `ldid -S<entitlements> ./clang`.
4. The app spawns it with `posix_spawn`, passing `PATH` and the cache directory
   the stub asks for (`SB_CACHE`, else `$XDG_CACHE_HOME`, else `$HOME/.cache`,
   else `TMPDIR`).

## Verification is static, on purpose

An iOS Mach-O cannot be executed on the macOS runner that built it, so the
smoke test for these columns is *not* "run `--version`". It is: parse the Mach-O
header and load commands in pure Python (`scripts/checkbin.py`), assert the
platform and deployment target, assert that every imported dylib is in the dyld
shared cache, and compare the size against the manifest's budget. Anything that
claims to have executed an iOS binary during a CI build is lying; this is what
we do instead.
