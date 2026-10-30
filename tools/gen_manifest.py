#!/usr/bin/env python3
"""Regenerate manifest/tools.json.

The manifest is the single source of truth for the build matrix, so it is
generated from the tables below instead of hand-edited: a target is one row,
a tool is one block, and every cell that cannot be built carries the reason.

    python3 tools/gen_manifest.py            # rewrite manifest/tools.json
    python3 tools/gen_manifest.py --stdout   # print it

Rules the generator enforces:
  * every tool in TOOLS gets an entry for every target in TARGETS;
  * status is ga | experimental | planned | not-supported;
  * not-supported always carries a non-empty reason;
  * legacy entries (tools this file does not describe) are preserved verbatim.
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "manifest", "tools.json")

# ---------------------------------------------------------------- target table
# goos/goarch let scripts/stub-build.sh and matrix.py agree with the recipes
# without a second table. family decides how verification reads a binary.
TARGETS = {
    "linux-x86_64": dict(os="linux", arch="x86_64", goos="linux", goarch="amd64", family="elf",
                         abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                         meaning="fully static ELF: readelf -d prints zero DT_NEEDED; runs on any x86_64 Linux kernel"),
    "linux-arm64": dict(os="linux", arch="arm64", goos="linux", goarch="arm64", family="elf",
                        abi="musl", runs_on="ubuntu-24.04-arm", container="alpine:3.21",
                        meaning="fully static ELF for aarch64: the iOS sandbox guest, Apple Silicon VMs, ARM servers"),
    "linux-armv7": dict(os="linux", arch="armv7", goos="linux", goarch="arm", family="elf",
                        abi="musleabihf", runs_on="ubuntu-24.04-arm", container="alpine:3.21",
                        meaning="static EABI-hardfloat ELF for 32-bit ARM boards and old Android-era kernels"),
    "linux-386": dict(os="linux", arch="386", goos="linux", goarch="386", family="elf",
                      abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                      meaning="static 32-bit x86 ELF, for containers and VMs without a 64-bit kernel"),
    "linux-riscv64": dict(os="linux", arch="riscv64", goos="linux", goarch="riscv64", family="elf",
                          abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                          meaning="static riscv64 ELF (LP64D), for boards and QEMU targets"),
    "windows-x86_64": dict(os="windows", arch="x86_64", goos="windows", goarch="amd64", family="pe",
                           abi="mingw-w64", runs_on="windows-2022", container=None,
                           meaning="PE32+ with no non-system import beyond kernel32/msvcrt: static CRT (/MT), no vcruntime redistributable"),
    "windows-arm64": dict(os="windows", arch="arm64", goos="windows", goarch="arm64", family="pe",
                          abi="mingw-w64", runs_on="windows-2022", container=None,
                          meaning="native PE32+ for Windows on ARM; the x86_64 carrier runs there under emulation and prefers this payload"),
    "windows-386": dict(os="windows", arch="386", goos="windows", goarch="386", family="pe",
                        abi="mingw-w64", runs_on="windows-2022", container=None,
                        meaning="32-bit PE for legacy Windows; still useful for 32-bit-only toolchains"),
    "macos-arm64": dict(os="macos", arch="arm64", goos="darwin", goarch="arm64", family="macho",
                        abi="macos", runs_on="macos-14", container=None,
                        meaning="Mach-O importing only the dyld shared cache; host tool for cross-building iOS products"),
    "macos-x86_64": dict(os="macos", arch="x86_64", goos="darwin", goarch="amd64", family="macho",
                         abi="macos", runs_on="macos-13", container=None,
                         meaning="Intel Mac slice; lipo'd with arm64 into macos-universal"),
    "macos-universal": dict(os="macos", arch="universal", goos="darwin", goarch="universal", family="macho",
                            abi="macos", runs_on="macos-14", container=None, fat=["arm64", "x86_64"],
                            meaning="fat Mach-O (arm64 + x86_64): one download for Apple Silicon and Intel, both slices carrying native payloads"),
    "ios-arm64": dict(os="ios", arch="arm64", goos="ios", goarch="arm64", family="macho",
                      abi="iphoneos", runs_on="macos-14", container=None,
                      meaning="Mach-O for the iOS sandbox: nothing imported beyond libSystem/libc++/Foundation, code-signed by the host app"),
    "ios-arm64-sim": dict(os="ios", arch="arm64", goos="iossimulator", goarch="arm64", family="macho",
                          abi="iphonesimulator", runs_on="macos-14", container=None,
                          meaning="simulator slice, for running the bundle in an iOS Simulator lane"),
    "windows-universal": dict(os="windows", arch="universal", goos="windows", goarch="amd64", family="pe",
                              abi="mingw-w64", runs_on="windows-2022", container=None, fat=["x86_64", "arm64"],
                              meaning="one PE carrier (x86_64) that carries the arm64 payload too and picks it on ARM64 Windows"),
    "linux-universal": dict(os="linux", arch="x86_64", goos="linux", goarch="amd64", family="elf",
                            abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21", fat=[],
                            meaning="NOT a thing: the kernel will not load a foreign ELF. One file per arch is the physical limit; use the per-arch files"),
}


# ------------------------------------------------------------------- helpers

def cell(tier, status="ga", note="", entry=None, image=None, smoke=None,
         budget=None, version=None, paths=None):
    c = {"tier": tier, "status": status}
    if entry:
        c["entry"] = entry
    if image:
        c["image"] = image
    if note:
        c["notes"] = note
    if smoke:
        c["smoke"] = smoke
    if budget:
        c["size_budget_mb"] = budget
    if version:
        c["version"] = version
    if paths:
        c["paths"] = paths
    return c


def notsup(reason):
    return cell("none", "not-supported", reason)


def expand(tool_id, cells, entry):
    """Resolve per-target cells: exact, then os-*, then *-arch, then *."""
    out = {}
    for name, spec in TARGETS.items():
        if name == "linux-universal":
            # A foreign ELF cannot be loaded by the kernel: one file per arch is
            # the physical limit, so this target is a documented dead end.
            out[name] = notsup("the kernel execs the carrier it was built for; a "
                               "single Linux file cannot serve two architectures. "
                               "Ship the per-arch files, or a script that picks.")
            continue
        if name == "windows-universal":
            base = dict(cells.get("windows-x86_64") or cells.get("windows-*")
                        or cells.get("*-x86_64") or cells.get("*") or {})
            if base.get("status") in (None, "planned", "not-supported"):
                out[name] = dict(base)
                continue
            base["notes"] = ("x86_64 PE carrier that also carries the arm64 payload: it "
                             "runs natively on x64 and under emulation on ARM64 Windows, "
                             "where PROCESSOR_ARCHITEW6432 selects the native arm64 tree. "
                             + base.get("notes", ""))
            base.setdefault("entry", entry)
            base.setdefault("paths", ["bin"])
            out[name] = base
            continue
        os_name, arch = spec["os"], spec["arch"]
        pick = (cells.get(name) or cells.get(f"{os_name}-*")
                or cells.get(f"*-{arch}") or cells.get("*"))
        if pick is None:
            raise SystemExit(f"{tool_id}: no cell for {name}")
        c = dict(pick)
        c.setdefault("entry", entry)
        c.setdefault("paths", ["bin"])
        out[name] = c
    return out


def tool(id, name, version, license, method, upstream, provides, cells, entry,
         min_os=None, source=None, notes=None):
    t = {"id": id, "name": name, "version": version, "license": license,
         "method": method, "upstream": upstream, "provides": provides}
    if source:
        t["source"] = source
    if notes:
        t["notes"] = notes
    if min_os:
        t["min_os"] = min_os
    t["targets"] = expand(id, cells, entry)
    return t


STATIC_PE = ("PE32+ linking only kernel32/msvcrt (static CRT); no Visual C++ "
             "redistributable, no vcruntime140.dll beside the binary")
MACHO = ("Mach-O importing only dyld-shared-cache libraries; nothing to place "
         "beside the app")
IOS_CROSS = ("no host port: swiftc/rustc/go/clang for iOS is the macos-* bundle "
             "cross-compiling with -target arm64-apple-ios")


TOOLS = []

TOOLS.append(tool(
    "llvm", "Clang / LLVM", "20.1.8", "Apache-2.0 WITH LLVM-exception", "source",
    "https://github.com/llvm/llvm-project/releases/tag/llvmorg-20.1.8",
    ["clang", "clang++", "clang-cpp", "ld.lld", "lld", "llvm-ar", "llvm-ranlib",
     "llvm-nm", "llvm-strip", "llvm-objcopy", "llvm-objdump", "llvm-readelf",
     "llvm-size", "llvm-profdata", "llvm-install-name-tool", "llvm-lipo",
     "clang-format", "clangd", "clang-tidy"],
    {
        "linux-x86_64": cell("layer", "ga", budget=450,
            note="static libLLVM/libclang archives (LLVM_BUILD_LLVM_DYLIB=OFF, "
                 "CLANG_LINK_CLANG_DYLIB=OFF) so every tool is a zero-DT_NEEDED ELF; "
                 "lib/clang/<ver> resource dir ships as a hash-addressed layer shared "
                 "with every other clang-carrying bundle; clangd/clang-tidy behind "
                 "SB_LLVM_EXTRA=1"),
        "linux-arm64": cell("layer", "ga", budget=450,
            note="same recipe, native aarch64; the resource dir layer digest matches "
                 "the x86_64 build, so a project carrying both stores headers once"),
        "linux-armv7": cell("layer", "experimental", budget=380,
            note="32-bit thumb2 build; LLVM needs -DLLVM_BUILD_32_BITS=ON and a "
                 "musleabihf cross compiler, and takes ~6 h on two cores"),
        "linux-386": cell("layer", "experimental", budget=380,
            note="32-bit x86 build (LLVM_BUILD_32_BITS=ON); no JIT for 386, so "
                 "clang -c and lld work while clang -run does not"),
        "linux-riscv64": cell("layer", "experimental", budget=420,
            note="native riscv64 build; keep -DLLVM_TARGETS_TO_BUILD=RISCV;AArch64;X86 "
                 "to stay under the budget"),
        "windows-x86_64": cell("sfx", "experimental", budget=900,
            note="mingw-w64 build with -DLLVM_STATIC_LINK_CXX_STDLIB=ON and "
                 "-static in CMAKE_EXE_LINKER_FLAGS yields " + STATIC_PE +
                 "; the official clang+llvm-*-x86_64-pc-windows-msvc release is the "
                 "fallback and needs the VC runtime beside it"),
        "windows-arm64": cell("sfx", "experimental", budget=900,
            note="official aarch64-pc-windows-msvc release, or a mingw-w64 aarch64 "
                 "cross build for a static CRT; lld and clang both work, JIT is arm64 "
                 "only (no x86 JIT on ARM64 Windows)"),
        "windows-386": cell("sfx", "planned", budget=800,
            note="32-bit PE build; LLVM dropped i686 Windows hosts, so this is a "
                 "cross build producing a 32-bit clang, not a supported host"),
        "macos-arm64": cell("layer", "ga", budget=1500,
            note="Xcode toolchain, or the official LLVM release for darwin-arm64; "
                 "resource dir is a layer so clang and swiftc share one copy"),
        "macos-x86_64": cell("layer", "ga", budget=1500, note="Intel slice of the same tree"),
        "macos-universal": cell("layer", "ga", budget=2200,
            note="lipo of the two slices; the bundle carries both payloads and the "
                 "stub runs the one matching the host"),
        "ios-arm64": cell("layer", "experimental", budget=600,
            note="clang inside the sandbox: needs an SDK layer (-isysroot) and a "
                 "writable TMPDIR; link only with lld (ld64 needs the toolchain's "
                 "ld64.lld), and no JIT without a signed entitlement"),
        "ios-arm64-sim": cell("layer", "experimental", budget=600,
            note="same tree, simulator slice; used for running compile tests in CI"),
    }, "bin/clang", source="llvmorg-20.1.8"))

TOOLS.append(tool(
    "swift", "Swift", "6.0.3", "Apache-2.0", "release",
    "https://www.swift.org/download/",
    ["swift", "swiftc", "swift-build", "swift-package", "swift-format", "sourcekit-lsp"],
    {
        "linux-x86_64": cell("layer", "ga", budget=1400, image="ubuntu:24.04",
            note="official toolchain + the Static Linux SDK: `swift build --swift-sdk "
                 "x86_64-swift-linux-musl` emits a fully static ELF, so the compiler "
                 "is packaged but the output is not"),
        "linux-arm64": cell("layer", "ga", budget=1400, image="ubuntu:24.04",
            note="aarch64 toolchain + aarch64-swift-linux-musl SDK; same static output"),
        "linux-armv7": notsup("Swift publishes no armv7 Linux toolchain and the "
                             "runtime has no 32-bit ARM Linux port"),
        "linux-386": notsup("no 32-bit x86 Linux toolchain exists upstream"),
        "linux-riscv64": cell("layer", "experimental", budget=1400, image="ubuntu:24.04",
            note="experimental upstream riscv64 toolchain; the stdlib is built but "
                 "not every runtime component is validated"),
        "windows-x86_64": cell("sfx", "experimental", budget=1600,
            note="official Swift for Windows toolchain; needs the Visual C++ "
                 "redistributable, which the payload carries, and a Windows SDK for "
                 "linking (clang-cl + lld-link)"),
        "windows-arm64": notsup("Swift for Windows ships x86_64 only; arm64 hosts run "
                                "the x86_64 toolchain under emulation"),
        "windows-386": notsup("no 32-bit Windows Swift toolchain"),
        "macos-arm64": cell("layer", "ga", budget=2200,
            note="Xcode toolchain; for iOS work this is the host half — the iOS "
                 "parcel is the SDK, not a second compiler"),
        "macos-x86_64": cell("layer", "ga", budget=2200, note="Intel slice"),
        "macos-universal": cell("layer", "ga", budget=3000,
            note="both slices plus one shared stdlib layer"),
        "ios-arm64": notsup(IOS_CROSS),
        "ios-arm64-sim": notsup(IOS_CROSS),
    }, "bin/swift"))

TOOLS.append(tool(
    "theos", "Theos + Logos", "2024.11", "GPL-3.0-or-later", "source",
    "https://github.com/theos/theos",
    ["theos", "logos.pl", "logify.pl", "nic.pl", "dm.pl"],
    {
        "linux-x86_64": cell("layer", "experimental", budget=120,
            note="theos on Linux: perl + make + the shared makefiles. Needs a clang "
                 "layer and a theos SDK; without them `make package` fails at "
                 "compile time, which the recipe checks at pack time"),
        "linux-arm64": cell("layer", "experimental", budget=120, note="same tree"),
        "linux-armv7": notsup("no iOS SDK can be assembled for an armv7 host; theos "
                             "host tooling is 64-bit only"),
        "linux-386": notsup("theos host tooling is 64-bit only"),
        "linux-riscv64": cell("layer", "planned", note="pure perl+make, so a tree "
            "copy should work; unexercised"),
        "windows-x86_64": notsup("theos is a Makefile+perl build system over a POSIX "
                                "shell; WSL or a Linux container is the supported path"),
        "windows-arm64": notsup("same as windows-x86_64"),
        "windows-386": notsup("same as windows-x86_64"),
        "macos-arm64": cell("layer", "ga", budget=140,
            note="the supported host: theos + SDK symlinks + logos; pairs with the "
                 "llvm layer for ld64.lld and the Darwin SDK"),
        "macos-x86_64": cell("layer", "ga", budget=140, note="same tree"),
        "macos-universal": cell("layer", "ga", budget=200, note="scripts are arch-neutral"),
        "ios-arm64": cell("layer", "experimental", budget=140,
            note="theos inside iSH: perl + make + ldid work; compiling needs clang and "
                 "an SDK, both of which are layers of their own"),
        "ios-arm64-sim": notsup("no simulator host inside the device sandbox"),
    }, "bin/theos"))

TOOLS.append(tool(
    "rust", "Rust", "1.83.0", "MIT OR Apache-2.0", "release",
    "https://static.rust-lang.org/dist/",
    ["rustc", "cargo", "rustdoc", "rustfmt", "clippy-driver", "rust-analyzer"],
    {
        "linux-x86_64": cell("layer", "ga", budget=900, image="ubuntu:24.04",
            note="rustup dist is glibc-linked, so the bundle is a layer, not a static "
                 "ELF; the compiler still emits fully static binaries with "
                 "`--target x86_64-unknown-linux-musl` and +crt-static"),
        "linux-arm64": cell("layer", "ga", budget=900, image="ubuntu:24.04",
            note="aarch64 dist + aarch64-unknown-linux-musl std; the usual iOS path is "
                 "this toolchain plus targets aarch64-apple-ios"),
        "linux-armv7": cell("layer", "experimental", budget=800, image="ubuntu:24.04",
            note="armv7-unknown-linux-gnueabihf host toolchain from rustup; "
                 "armv7-unknown-linux-musleabihf std gives static output"),
        "linux-386": notsup("rustup publishes no i686-unknown-linux-musl host "
                            "toolchain; cross-compile from x86_64 instead"),
        "linux-riscv64": cell("layer", "experimental", budget=900, image="ubuntu:24.04",
            note="riscv64gc-unknown-linux-musl std exists; a native host toolchain "
                 "must be assembled from the dist channel"),
        "windows-x86_64": cell("sfx", "ga", budget=900,
            note="x86_64-pc-windows-gnu (mingw) plus x86_64-pc-windows-msvc targets; "
                 "+crt-static in .cargo/config.toml yields " + STATIC_PE),
        "windows-arm64": cell("sfx", "experimental", budget=900,
            note="aarch64-pc-windows-msvc needs the MS linker, aarch64-pc-windows-gnullvm "
                 "works with clang/lld — the gnullvm route is the one that stays static"),
        "windows-386": notsup("i686-pc-windows-msvc is tier-1 but no host toolchain is "
                              "published for it"),
        "macos-arm64": cell("layer", "ga", budget=1000, note="rustup aarch64-apple-darwin"),
        "macos-x86_64": cell("layer", "ga", budget=1000, note="x86_64-apple-darwin"),
        "macos-universal": cell("layer", "ga", budget=1400,
            note="rustup ships universal-apple-darwin: one compiler, both slices, and "
                 "`cargo build --target aarch64-apple-ios` cross-links iOS"),
        "ios-arm64": notsup(IOS_CROSS + "; add aarch64-apple-ios via `rustup target add`"),
        "ios-arm64-sim": notsup(IOS_CROSS),
    }, "bin/rustc", source="rust-1.83.0"))


TOOLS.append(tool(
    "go", "Go", "1.23.9", "BSD-3-Clause", "release",
    "https://go.dev/dl/",
    ["go", "gofmt", "goimports"],
    {
        "linux-x86_64": cell("layer", "ga", budget=260,
            note="official tarball; CGO_ENABLED=0 output is statically linked by "
                 "construction, and GOROOT ships as a layer shared with every other "
                 "Go-carrying bundle"),
        "linux-arm64": cell("layer", "ga", budget=250, note="same, aarch64 tarball"),
        "linux-armv7": cell("layer", "ga", budget=240,
            note="linux-armv6l tarball covers armv6/armv7 boards; GOARM selects the "
                 "instruction set at compile time"),
        "linux-386": cell("layer", "ga", budget=240, note="linux-386 tarball"),
        "linux-riscv64": cell("layer", "ga", budget=250,
            note="linux-riscv64 tarball (first class since 1.21)"),
        "windows-x86_64": cell("layer", "ga", budget=260,
            note="windows-amd64 zip; binaries are " + STATIC_PE +
                 " with CGO_ENABLED=0, and GOROOT is the only thing carried"),
        "windows-arm64": cell("layer", "ga", budget=250, note="windows-arm64 zip, native"),
        "windows-386": cell("layer", "experimental", budget=240,
            note="windows-386 zip; 32-bit Go still builds and runs on 64-bit Windows"),
        "macos-arm64": cell("layer", "ga", budget=260, note="darwin-arm64 tarball"),
        "macos-x86_64": cell("layer", "ga", budget=260, note="darwin-amd64 tarball"),
        "macos-universal": cell("layer", "ga", budget=340,
            note="one GOROOT plus two tool slices; `go build` targets iOS with "
                 "GOOS=ios GOARCH=arm64 and cgo"),
        "ios-arm64": cell("layer", "experimental", budget=200,
            note="GOOS=ios needs cgo and the iOS SDK; without them only pure-Go "
                 "packages build, and the resulting binary is app-signed, not standalone"),
        "ios-arm64-sim": cell("layer", "experimental", budget=200, note="same, simulator slice"),
    }, "bin/go", source="go1.23.9"))

TOOLS.append(tool(
    "zig", "Zig", "0.14.0", "MIT", "release",
    "https://ziglang.org/download/",
    ["zig"],
    {
        "linux-x86_64": cell("static", "ga", budget=180,
            note="single static binary; also a full C/C++ cross compiler "
                 "(`zig cc -target aarch64-linux-musl`), which is how this repository "
                 "cross-builds ELF from a macOS host"),
        "linux-arm64": cell("static", "ga", budget=170, note="aarch64-linux tarball"),
        "linux-armv7": cell("static", "experimental", budget=170,
            note="no armv7 host build; runs the aarch64/aarch64-emulated compiler and "
                 "targets arm-linux-musleabihf"),
        "linux-386": cell("static", "experimental", budget=170,
            note="no i386 host build; x86_64 bin targets x86-linux-musl"),
        "linux-riscv64": cell("static", "experimental", budget=170,
            note="no riscv64 host build upstream; cross-targeting works"),
        "windows-x86_64": cell("static", "ga", budget=180, note="zig-windows-x86_64, one PE"),
        "windows-arm64": cell("static", "ga", budget=180, note="zig-windows-aarch64"),
        "windows-386": notsup("no 32-bit Windows host build"),
        "macos-arm64": cell("static", "ga", budget=180, note="zig-macos-aarch64"),
        "macos-x86_64": cell("static", "ga", budget=180, note="zig-macos-x86_64"),
        "macos-universal": cell("static", "ga", budget=240, note="lipo of both slices"),
        "ios-arm64": cell("static", "experimental", budget=180,
            note="zig can compile for aarch64-ios given the SDK; the binary still has "
                 "to be signed by the enclosing app"),
        "ios-arm64-sim": cell("static", "experimental", budget=180, note="simulator target"),
    }, "bin/zig", source="0.14.0"))

TOOLS.append(tool(
    "python", "CPython", "3.12.7", "PSF-2.0", "release",
    "https://github.com/astral-sh/python-build-standalone/releases",
    ["python3", "pip3", "python"],
    {
        "linux-x86_64": cell("layer", "ga", budget=120,
            note="python-build-standalone install_only (musl): self-contained, no "
                 "system libpython; stdlib is a layer so meson and other Python tools "
                 "reuse it instead of shipping a second copy"),
        "linux-arm64": cell("layer", "ga", budget=120, note="aarch64 musl build"),
        "linux-armv7": notsup("no upstream armv7/hardfloat build; cross-compiling "
                              "CPython for armv7 is a project, not a fetch"),
        "linux-386": notsup("python-build-standalone has no 32-bit x86 Linux build"),
        "linux-riscv64": cell("layer", "experimental", budget=120,
            note="riscv64 musl build exists in newer PBS releases; unexercised here"),
        "windows-x86_64": cell("sfx", "ga", budget=110,
            note="PBS windows-amd64: python.exe plus the DLLs it needs, all inside the "
                 "payload; embeddable-zip needs a separate stdlib and is not used"),
        "windows-arm64": cell("sfx", "experimental", budget=110,
            note="windows-arm64 builds land in recent PBS releases; the x86_64 build "
                 "runs under emulation in the meantime"),
        "windows-386": notsup("no 32-bit Windows CPython build in PBS"),
        "macos-arm64": cell("layer", "ga", budget=120, note="PBS darwin-arm64"),
        "macos-x86_64": cell("layer", "ga", budget=120, note="PBS darwin-x86_64"),
        "macos-universal": cell("layer", "ga", budget=170,
            note="PBS universal2 build: one tree, both slices"),
        "ios-arm64": cell("layer", "experimental", budget=90,
            note="CPython builds for iOS (3.13 added an official iOS target) but only "
                 "as a framework for an app: no fork/exec, no subprocess"),
        "ios-arm64-sim": notsup("simulator builds come from the app's own Xcode build"),
    }, "bin/python3", source="3.12.7"))


NODE_NOTE = ("official Node build + npm; libnode is glibc/musl-linked, so the bundle "
             "is a layer rather than a single static ELF")

TOOLS.append(tool(
    "node", "Node.js", "22.11.0", "MIT", "release",
    "https://nodejs.org/dist/",
    ["node", "npm", "npx", "corepack"],
    {
        "linux-x86_64": cell("layer", "ga", budget=140, note=NODE_NOTE + " (linux-x64 glibc)"),
        "linux-arm64": cell("layer", "ga", budget=140, note=NODE_NOTE + " (linux-arm64)"),
        "linux-armv7": cell("layer", "experimental", budget=130,
            note="linux-armv7l build exists upstream; npm's dependency tree is heavier "
                 "than the runtime and dominates the payload"),
        "linux-386": notsup("Node dropped 32-bit Linux builds after 10.x"),
        "linux-riscv64": cell("layer", "planned", budget=140,
            note="unofficial-builds.nodejs.org carries riscv64; not a first-class "
                 "support level"),
        "windows-x86_64": cell("sfx", "ga", budget=130, note="node.exe + npm; win-x64 zip"),
        "windows-arm64": cell("sfx", "experimental", budget=130,
            note="win-arm64 zip exists; some native addons still ship x64-only prebuilds"),
        "windows-386": notsup("no 32-bit Windows Node build"),
        "macos-arm64": cell("layer", "ga", budget=140, note="darwin-arm64 tarball"),
        "macos-x86_64": cell("layer", "ga", budget=140, note="darwin-x64 tarball"),
        "macos-universal": cell("layer", "ga", budget=200,
            note="lipo of both node binaries plus one shared node_modules layer"),
        "ios-arm64": cell("layer", "experimental", budget=110,
            note="needs a jitless build (--jitless / V8 without RWX pages): the iOS "
                 "sandbox denies JIT unless the app holds an entitlement"),
        "ios-arm64-sim": cell("layer", "experimental", budget=110, note="simulator slice"),
    }, "bin/node", source="v22.11.0"))

TOOLS.append(tool(
    "typescript", "TypeScript", "5.7.2", "Apache-2.0", "release",
    "https://registry.npmjs.org/typescript",
    ["tsc", "tsserver"],
    {
        "linux-x86_64": cell("layer", "ga", budget=90,
            note="tsc is JavaScript: the payload is the npm tarball plus a node layer, "
                 "and both share the node tree rather than duplicating it"),
        "linux-arm64": cell("layer", "ga", budget=90, note="same tree; node layer supplies the runtime"),
        "linux-armv7": cell("layer", "experimental", budget=90, note="node layer must be built first"),
        "linux-386": notsup("no 32-bit Node runtime to host tsc"),
        "linux-riscv64": cell("layer", "planned", budget=90, note="depends on the node riscv64 layer"),
        "windows-x86_64": cell("sfx", "ga", budget=90, note="tsc.cmd shim + node.exe from the node layer"),
        "windows-arm64": cell("sfx", "experimental", budget=90, note="needs the node arm64 layer"),
        "windows-386": notsup("no 32-bit Node runtime to host tsc"),
        "macos-arm64": cell("layer", "ga", budget=90, note="tsc + node layer"),
        "macos-x86_64": cell("layer", "ga", budget=90, note="tsc + node layer"),
        "macos-universal": cell("layer", "ga", budget=110, note="one JS tree, two node slices"),
        "ios-arm64": cell("layer", "experimental", budget=70, note="works with a jitless node layer"),
        "ios-arm64-sim": cell("layer", "experimental", budget=70, note="simulator slice"),
    }, "bin/tsc"))

TOOLS.append(tool(
    "java", "OpenJDK (JRE + jlink)", "21.0.5", "GPL-2.0 WITH Classpath-exception-2.0",
    "release", "https://adoptium.net/temurin/releases/",
    ["java", "javac", "jar", "jlink", "jshell", "keytool"],
    {
        "linux-x86_64": cell("layer", "ga", budget=200, image="ubuntu:24.04",
            note="Temurin JDK, jlink'd to a runtime image with the modules a build "
                 "actually needs; the runtime is a layer so java, kotlin and tooling "
                 "share one JRE"),
        "linux-arm64": cell("layer", "ga", budget=200, image="ubuntu:24.04", note="aarch64 JDK"),
        "linux-armv7": cell("layer", "experimental", budget=160, image="ubuntu:24.04",
            note="Temurin has an arm32 build for some releases; jlink works, the "
                 "runtime is larger relative to the compiler"),
        "linux-386": notsup("no 32-bit x86 JDK is published for current releases"),
        "linux-riscv64": cell("layer", "experimental", budget=200, image="ubuntu:24.04",
            note="riscv64 JDK builds exist (Temurin/IBM); JIT support varies"),
        "windows-x86_64": cell("sfx", "ga", budget=210, note="Temurin windows-x64 + jlink image"),
        "windows-arm64": cell("sfx", "experimental", budget=210,
            note="Microsoft OpenJDK ships windows-aarch64; jlink the same way"),
        "windows-386": notsup("no 32-bit Windows JDK for current releases"),
        "macos-arm64": cell("layer", "ga", budget=200, note="Temurin macos-aarch64"),
        "macos-x86_64": cell("layer", "ga", budget=200, note="Temurin macos-x64"),
        "macos-universal": cell("layer", "ga", budget=280,
            note="two jlink images sharing one class-data layer"),
        "ios-arm64": notsup("no JVM port to iOS: JIT is forbidden by the sandbox and "
                            "no interpreter-only JVM ships for arm64-ios"),
        "ios-arm64-sim": notsup("same: no JVM port to the iOS simulator platform"),
    }, "bin/java", source="21.0.5"))

TOOLS.append(tool(
    "kotlin", "Kotlin", "2.1.0", "Apache-2.0", "release",
    "https://github.com/JetBrains/kotlin/releases",
    ["kotlinc", "kotlin", "kotlinc-jvm", "kapt"],
    {
        "linux-x86_64": cell("layer", "ga", budget=180,
            note="kotlin-compiler.zip + a java layer; the JRE is not duplicated"),
        "linux-arm64": cell("layer", "ga", budget=180, note="same jar, aarch64 JRE layer"),
        "linux-armv7": cell("layer", "experimental", budget=150, note="arm32 JRE layer"),
        "linux-386": notsup("no 32-bit JRE to run the Kotlin compiler"),
        "linux-riscv64": cell("layer", "experimental", budget=180, note="riscv64 JRE layer"),
        "windows-x86_64": cell("sfx", "ga", budget=190, note="kotlinc.bat + JRE layer"),
        "windows-arm64": cell("sfx", "experimental", budget=190, note="arm64 JRE layer"),
        "windows-386": notsup("no 32-bit JRE"),
        "macos-arm64": cell("layer", "ga", budget=190, note="darwin-aarch64 JRE layer"),
        "macos-x86_64": cell("layer", "ga", budget=190, note="darwin-x64 JRE layer"),
        "macos-universal": cell("layer", "ga", budget=220, note="shared jar, two JRE slices"),
        "ios-arm64": notsup("JVM-only compiler: no JVM exists on iOS. Kotlin/Native "
                            "targets iOS from a macos-* host instead"),
        "ios-arm64-sim": notsup("same as ios-arm64"),
    }, "bin/kotlinc"))


GNU_MAKE = ("GNU make from source; make has no runtime dependencies worth speaking of, "
            "which is why it is the one build tool that is a single static file on every "
            "platform")

TOOLS.append(tool(
    "make", "GNU Make", "4.4.1", "GPL-3.0-or-later", "source",
    "https://ftp.gnu.org/gnu/make/",
    ["make", "gmake"],
    {
        "linux-x86_64": cell("static", "ga", budget=3, note=GNU_MAKE),
        "linux-arm64": cell("static", "ga", budget=3, note=GNU_MAKE),
        "linux-armv7": cell("static", "ga", budget=3, note=GNU_MAKE + " (musleabihf)"),
        "linux-386": cell("static", "ga", budget=3, note=GNU_MAKE + " (32-bit x86)"),
        "linux-riscv64": cell("static", "ga", budget=3, note=GNU_MAKE + " (riscv64)"),
        "windows-x86_64": cell("static", "experimental", budget=3,
            note="mingw-w64 build of 4.4.1; a POSIX shell must be on PATH for recipes, "
                 "which is exactly what a make bundle is for on Windows"),
        "windows-arm64": cell("static", "planned", budget=3,
            note="mingw-w64 aarch64 cross build; unexercised"),
        "windows-386": cell("static", "planned", budget=3, note="i686-w64-mingw32 build"),
        "macos-arm64": cell("macho", "ga", budget=3, note=GNU_MAKE + " (arm64 slice)"),
        "macos-x86_64": cell("macho", "ga", budget=3, note=GNU_MAKE + " (x86_64 slice)"),
        "macos-universal": cell("macho", "ga", budget=4, note="lipo of both slices"),
        "ios-arm64": cell("macho", "ga", budget=3,
            note="runs in the sandbox: make only needs a shell and a filesystem"),
        "ios-arm64-sim": cell("macho", "ga", budget=3, note="simulator slice"),
    }, "bin/make"))

TOOLS.append(tool(
    "ninja", "Ninja", "1.12.1", "Apache-2.0", "source",
    "https://github.com/ninja-build/ninja/releases",
    ["ninja", "samu"],
    {
        "linux-x86_64": cell("static", "ga", budget=3,
            note="C++ build with -static; 600 KiB and zero DT_NEEDED"),
        "linux-arm64": cell("static", "ga", budget=3, note="native aarch64 build"),
        "linux-armv7": cell("static", "ga", budget=3, note="musleabihf build"),
        "linux-386": cell("static", "ga", budget=3, note="32-bit x86 build"),
        "linux-riscv64": cell("static", "ga", budget=3, note="riscv64 build"),
        "windows-x86_64": cell("static", "ga", budget=3,
            note="official ninja-win.zip is a single static PE; the source build with "
                 "-static also works under mingw-w64"),
        "windows-arm64": cell("static", "experimental", budget=3,
            note="mingw-w64 aarch64 build; ninja has no arch-specific code paths"),
        "windows-386": cell("static", "experimental", budget=3, note="i686 mingw build"),
        "macos-arm64": cell("macho", "ga", budget=3, note="cmake build, arm64 slice"),
        "macos-x86_64": cell("macho", "ga", budget=3, note="x86_64 slice"),
        "macos-universal": cell("macho", "ga", budget=4, note="lipo both slices"),
        "ios-arm64": cell("macho", "ga", budget=3, note="runs in the sandbox; used by theos"),
        "ios-arm64-sim": cell("macho", "ga", budget=3, note="simulator slice"),
    }, "bin/ninja"))

TOOLS.append(tool(
    "meson", "Meson", "1.6.0", "Apache-2.0", "source",
    "https://github.com/mesonbuild/meson/releases",
    ["meson", "meson-python"],
    {
        "linux-x86_64": cell("layer", "ga", budget=40,
            note="pure Python: the payload is the meson wheel tree plus a python layer, "
                 "shared with every other Python tool (ninja stays a separate bundle)"),
        "linux-arm64": cell("layer", "ga", budget=40, note="same tree, aarch64 python layer"),
        "linux-armv7": cell("layer", "experimental", budget=40, note="requires an armv7 python layer"),
        "linux-386": notsup("no 32-bit Python layer to run meson"),
        "linux-riscv64": cell("layer", "experimental", budget=40, note="riscv64 python layer"),
        "windows-x86_64": cell("sfx", "ga", budget=40, note="meson.exe shim + python layer from python-*"),
        "windows-arm64": cell("sfx", "experimental", budget=40, note="needs the python arm64 layer"),
        "windows-386": notsup("no 32-bit Python layer"),
        "macos-arm64": cell("layer", "ga", budget=40, note="python layer + wheel tree"),
        "macos-x86_64": cell("layer", "ga", budget=40, note="same"),
        "macos-universal": cell("layer", "ga", budget=50, note="one wheel tree, universal python layer"),
        "ios-arm64": cell("layer", "experimental", budget=30,
            note="meson only generates build files, so it runs even where a compiler "
                 "cannot: the build itself still needs clang"),
        "ios-arm64-sim": cell("layer", "experimental", budget=30, note="simulator slice"),
    }, "bin/meson"))


# Cells whose approach is documented but whose recipe branch is not written
# yet. Status honesty matters more than coverage in the table: `experimental`
# means "this recipe has a branch for the target", `planned` means "it does
# not". Demoting is a one-line edit here, and the note says what is missing.
DEMOTE = {
    "llvm": [("windows-*", "the mingw-w64 / clang-cl branch is not written; the "
                           "approach (static libLLVM + -static, or the MSVC release "
                           "plus its redistributable) is in docs/targets.md"),
             ("linux-armv7", "needs a musleabihf host runner; the recipe builds natively only"),
             ("linux-386", "needs an i686 host; LLVM_BUILD_32_BITS is set but unbuilt here"),
             ("linux-riscv64", "needs a riscv64 runner; unexercised")],
    "swift": [("windows-*", "Swift for Windows needs the MSVC toolchain and SDK; "
                            "the recipe targets the Linux/macOS toolchains only")],
    "python": [("windows-*", "the recipe builds CPython from source with a POSIX "
                             "toolchain; a Windows build needs a mingw cross build "
                             "plus patched Modules/Setup"),
               ("linux-armv7", "no armv7 cross toolchain in the recipe"),
               ("linux-386", "no i686 cross toolchain in the recipe"),
               ("linux-riscv64", "no riscv64 cross toolchain in the recipe")],
    "typescript": [("windows-*", "needs the node layer on Windows first")],
    "meson": [("windows-*", "needs the python layer on Windows first")],
    "theos": [("windows-*", "not supported by upstream; nothing to write")],
    "java": [("windows-arm64", "jlink emits a runtime for its own host only; needs a "
                               "windows-arm64 runner"),
             ("linux-armv7", "Temurin publishes no current arm32 build to jlink from")],
    "kotlin": [("windows-arm64", "jlink emits a runtime for its own host only"),
               ("linux-armv7", "needs the arm32 JRE that java cannot build")],
}


def demote(tools):
    for tool in tools:
        for pattern, reason in DEMOTE.get(tool["id"], []):
            for name, block in tool["targets"].items():
                os_name, _, arch = name.partition("-")
                if pattern in (name, f"{os_name}-*", f"*-{arch}", "*-*"):
                    if block.get("status") in ("ga", "experimental"):
                        block["status"] = "planned"
                        block["notes"] = reason


# ---------------------------------------------------------------------- emit

def legacy_entries(new_by_id):
    """Keep tools this generator does not describe, with an honest target gap."""
    if not os.path.isfile(MANIFEST):
        return []
    with open(MANIFEST) as fh:
        old = json.load(fh)
    kept = []
    for t in old.get("tools", []):
        if t["id"] in new_by_id:
            continue
        targets = t.setdefault("targets", {})
        for name in TARGETS:
            if name in targets:
                continue
            targets[name] = (cell("none", "planned",
                                 "no Windows/extra-arch branch in recipes/%s.sh yet" % t["id"])
                             if name.split("-")[0] in ("windows",) or
                             name.split("-")[1] in ("armv7", "386", "riscv64") else
                             cell(targets.get("linux-arm64", {}).get("tier", "sfx"),
                                  "planned", "recipe not exercised on this target"))
        kept.append(t)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args()

    tools = list(TOOLS)
    tools.extend(legacy_entries({t["id"] for t in TOOLS}))
    demote(tools)
    tools.sort(key=lambda t: t["id"])

    problems = []
    for t in tools:
        for name, c in t["targets"].items():
            if c["status"] == "not-supported" and not c.get("notes"):
                problems.append(f"{t['id']}/{name}: not-supported without a reason")
            if c["status"] in ("ga", "experimental") and not c.get("entry"):
                problems.append(f"{t['id']}/{name}: buildable without an entry")
    if problems:
        print("\n".join("FAIL: " + p for p in problems), file=sys.stderr)
        return 1

    doc = {
        "schema": 2,
        "updated": "2026-10-30",
        "tiers": {
            "static": "one binary, zero non-system imports (ELF: DT_NEEDED empty; PE: only kernel32/msvcrt; Mach-O: dyld cache only)",
            "macho": "one Mach-O importing only OS-shipped dylibs",
            "sfx": "static carrier + zstd blob region carrying a tree (compiler resources, stdlib, JRE)",
            "layer": "sfx whose shared runtime trees are content-addressed, so two bundles carrying the same JRE/stdlib store it once on disk",
            "none": "not buildable for this target; see notes",
        },
        "status_legend": {
            "ga": "built, verified and exercised by CI on this target",
            "experimental": "recipe exists and compiles, but the target is not covered by the green matrix",
            "planned": "declared with a known approach, recipe branch not written yet",
            "not-supported": "physically or upstream impossible; the reason is in notes",
        },
        "targets": {k: v for k, v in sorted(TARGETS.items())},
        "tools": tools,
    }
    body = json.dumps(doc, indent=1) + "\n"
    if args.stdout:
        sys.stdout.write(body)
    else:
        os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
        with open(MANIFEST, "w") as fh:
            fh.write(body)
        buildable = sum(1 for t in tools for c in t["targets"].values()
                        if c["status"] in ("ga", "experimental"))
        print(f"manifest: {len(tools)} tools, {len(TARGETS)} targets, "
              f"{buildable} buildable cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
