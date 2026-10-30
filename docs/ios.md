# iOS

This is the target the repository exists for. It is also the target with the most
constraints, so this page is blunt about what works.

## What runs on iOS, and how

A sandboxed app may `posix_spawn` an executable that lives inside its own bundle
and is signed with the app's identity. That is the mechanism a-Shell, iSH and
TheosStudio all use. Nothing in this repository changes that rule; it only makes
the executable single-file and dependency-free.

Consequences:

* **Every Mach-O artifact must be signed with the host app's identity at embed
  time**, or re-signed on device with `ldid` when the app has a jailbreak context.
  The repository ships unsigned binaries on purpose: it cannot know your team ID.
* **`fork()` does not exist.** Tools that shell out (`cmake`, `git`, `make`) use
  `posix_spawn` on Darwin; glibc-isms compile but fail at run time. Recipes build
  with `-DHAVE_POSIX_SPAWN`, and `docs/caveats.md` lists the tools that still call
  `fork()` internally.
* **No `execve` of scripts.** `#!/usr/bin/env python3` does not resolve in a
  sandbox. Bundle entry points are Mach-O executables; scripts (like the `kotlinc`
  wrapper) are invoked as `sh wrapper`, never via shebang.
* **No writable `/usr`, no `$HOME` guarantee.** Bundles extract into
  `$SB_CACHE`, else `$XDG_CACHE_HOME`, else `$HOME/.cache`, else `TMPDIR` — the
  stub's `cacheDir()` tries them in that order because on iOS `HOME` can point at
  the app container and `TMPDIR` can be pruned by the system.
* **JIT is forbidden.** Any tool whose value depends on executable memory
  generation (stock Node, LuaJIT, PyPy, JVM) needs a jitless build or does not
  ship. `node` is built from nodejs-mobile for exactly this reason.
* **Memory limits are real.** A 200 MiB clang linking a 4 MB binary is fine; LLVM
  LTO on a phone is not. `docs/caveats.md` marks the tools that need
  `-fno-lto` on device.

## Embedding a bundle

```swift
// 1. Ship the artifact as a resource, no extension.
//    Copying to a writable location first is required: iOS will not exec from
//    the read-only bundle path on all iOS versions.
let src = Bundle.main.url(forResource: "clang-20.1.8-ios-arm64", withExtension: nil)!
let dst = FileManager.default.temporaryDirectory.appendingPathComponent("clang")
try? FileManager.default.removeItem(at: dst)
try FileManager.default.copyItem(at: src, to: dst)

// 2. Keep it executable. On a signed device the copy keeps the app's signature;
//    after any modification (or for a jailbroken device) re-sign with ldid:
//    dst -> "ldid -S<entitlements> clang"

// 3. Run it with a clean environment.
var env = ["SB_CACHE": cacheDir.path, "PATH": "\(cacheDir.path)/bin:/usr/bin:/bin"]
var pid: pid_t = 0
var argv: [UnsafeMutablePointer<CChar>?] = [strdup(dst.path), strdup("--version"), nil]
posix_spawn(&pid, dst.path, nil, nil, &argv, env.map { strdup("\($0.key)=\($0.value)") } + [nil])
```

`posix_spawn` traps worth knowing:

* the file must be executable (`chmod 0755`) **and** signed; a `kill(SIGKILL)`
  immediately after spawn is almost always a code-signing failure;
* pass `POSIX_SPAWN_CLOEXEC_DEFAULT` in the flags if you do not want the bundle's
  pipes and sockets inherited;
* the environment must not contain `DYLD_*` — the kernel strips them, and Apple
  logs a warning that reads like a crash.

## Recommended sets

| Host app kind | Bundles |
|---|---|
| On-device tweak builder (TheosStudio-style) | `make`, `ldid`, `dpkg`, `theos`, `clang` (with an SDK tree the app already carries) |
| On-device general IDE | `clang`, `python`, `node`, `typescript`, `cmake`, `ninja`, `git`, `tar`, `xz`, `zstd`, `busybox` |
| Linux-guest app (iSH / linuxkit) | the `linux-arm64` column instead; nothing needs a Mach-O build |
| Desktop cross-compiler for iOS apps | `linux-arm64` or `macos-arm64` bundles: `swift`, `rust`, `go`, `zig`, `xtool` |

## What is deliberately not here

`xcodebuild`, real `codesign`, `swiftc` as an iOS *host*, and any App Store
submission tooling. They require macOS and Apple's private steps; shipping a
shim would be a lie with a download button.
