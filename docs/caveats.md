# Caveats

Everything here is a fact that cost time to find, written down so it costs time once.

## Licensing — read before shipping commercially

| Component | Licence | What it means for a bundle you redistribute |
|---|---|---|
| LLVM / Clang | Apache-2.0 WITH LLVM-exception | Safe to ship; keep `LICENSE.TXT` in the bundle (`.sb/LICENSE`). |
| GNU make, dpkg, ccache, QEMU, fakeroot, patchelf | GPL-2/3 | Shipping the binary is fine; you must offer the corresponding source. `dist/<tool>.src.tar.xz` is produced for these. |
| ldid | AGPL-3.0 | Network-facing use triggers source disclosure. On-device signing is not network-facing, but the AGPL is the strictest licence in the catalog — decide deliberately. |
| OpenJDK (Temurin) | GPL-2.0 WITH Classpath-exception-2.0 | Redistributable; keep the `legal/` directory from the JDK. |
| Kotlin compiler | Apache-2.0 | Fine; it embeds JetBrains' `trove4j` (LGPL) — keep its notice. |
| Swift toolchain | Apache-2.0 + runtime exception | Redistributable including the runtime. |
| Rust | MIT/Apache-2.0 dual | Fine. |
| Go | BSD-3 | Fine. |
| Node.js | MIT, with V8 (BSD) and OpenSSL (Apache-2.0) inside | Fine; the jitless iOS build inherits nodejs-mobile's notices. |
| Python | PSF-2.0 | Fine; keep `LICENSE.txt`. |
| Xcode SDKs, `.tbd` stubs, `libSystem`, `libc++` headers | Apple, not redistributable | **Not shipped.** Any recipe that needs them takes a path from the environment. |
| Android SDK / NDK | Google terms, not redistributable | Not in this repo; `android-sdk` is listed as not-supported for that reason. |

The rule: if a bundle grows a file whose licence this table does not cover, add
a row here in the same pull request. CI does not judge licences; a human does.

## Not buildable, and why

| Tool | Why not | What to do instead |
|---|---|---|
| `xcodebuild`, `codesign`, `xcrun` | Apple-private, macOS-only, requires a developer identity. | Ship `ldid` + `ldid -S`; use `xtool` for a no-Xcode build on a Mac/Linux host. |
| `swiftc` as an iOS host | No `aarch64-apple-ios` host port; Swift is cross-only. | Use the `macos-arm64`/`linux-arm64` Swift bundle. |
| `rustc` as an iOS host | `rust-std` exists for `aarch64-apple-ios` as a *target* only. | Use the cross bundle and `--target aarch64-apple-ios`. |
| `go` as an iOS host | `GOOS=ios` is a target, never a host. | Same: cross bundle. |
| `zig` as an iOS host | iOS is not in Zig's host list. | Same. |
| JVM (Java, Kotlin, Gradle) on iOS | No HotSpot port; JIT and `mprotect(PROT_EXEC)` are unavailable. | Run them in the Linux guest (`linux-arm64` bundles via iSH/linuxkit). |
| `fakeroot` on iOS | Uses `LD_PRELOAD`. | Use `dpkg-deb --build` with `--root-owner-group`; no fakeroot needed. |
| `patchelf` on iOS | ELF-only tool. | Not applicable; Mach-O editing is `install_name_tool` (in the LLVM bundle as `llvm-install-name-tool`). |
| `qemu-user-static` on iOS | Needs mmap of executable memory for TCG's generated code. | Use the Linux guest, where the sandbox permits `mprotect`. |
| `docker`, `podman` | Need namespaces and a privileged daemon. | Nothing; out of scope. |
| `git` submodules / `git svn` | Perl + network helpers; `git-svn` drags a Perl DBI chain. | `git` core only; submodules do work. |
| `gdb` | Depends on a ptrace policy iOS does not grant to apps. | `lldb` from the Swift toolchain, attached on a Mac. |

## Runtime caveats per bundle

* **clang (iOS)** — compiles for the running device only when the host app
  supplies an SDK tree; it cannot produce App Store-valid binaries (no entitlements
  signing, no bitcode). LTO is disabled by default in the recipe's `-O2` flags:
  `-flto` doubles peak memory and gets the app killed by jetsam.
* **python (iOS)** — `subprocess` works via `posix_spawn`; `os.fork` raises.
  `multiprocessing` works only with `set_start_method("spawn")`.
* **node (iOS)** — jitless V8 is 3–8× slower than JIT. `worker_threads` is
  compiled out; `vm.Script` works but cannot be cached to disk.
* **git (iOS)** — `GIT_EXEC_PATH` is set by the bundle; if the host app sets
  `GIT_TEMPLATE_DIR` to a non-existent path, `git init` fails with a confusing
  "template not found".
* **cmake (iOS)** — the generator spawns `make`/`ninja`; both must come from the
  bundle's `PATH` prefix, which the stub sets, but a host app that resets `PATH`
  after spawn breaks it.
* **qemu, proot (Linux guest only)** — require `ptrace`; iOS allows self-tracing,
  the sandbox guest inherits that, but a hardened runtime entitlement can remove it.
* **fakeroot (Linux)** — `faked` must be the same arch as `fakeroot`; the bundle
  carries both, and `FAKEROOTDONTTRYCHOWN=1` is set so a non-root user succeeds.

## Build-environment caveats

* `SOURCE_DATE_EPOCH` is fixed to `1700000000` unless overridden, which is what
  makes bundles byte-reproducible. Bumping it is a release decision.
* `zstd` must be on `PATH` for `pack.py`; `xz` for `.tar.xz` sources; `unzip` for
  `.zip` sources. `make deps` prints what each recipe needs.
* Static linking on musl is a house of cards when a project calls `dlopen`. Every
  recipe that hits it is classified `sfx` instead of `static`, and `verify.sh`
  enforces the claim rather than trusting the label.
* macOS runners cannot build static ELF without a cross toolchain. CI builds ELF
  on `ubuntu-24.04-arm` in an Alpine container; the Mach-O targets build on
  `macos-15`. Do not mix them up, the failure mode is a linked-against-glibc
  binary that "works" in CI and dies in the guest.
