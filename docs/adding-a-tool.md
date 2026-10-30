# Adding a tool

Three files, one rule.

1. **`manifest/tools.json`** — an entry under `tools`:

```json
{
  "id": "fd",
  "name": "fd",
  "version": "10.2.0",
  "license": "MIT OR Apache-2.0",
  "method": "source",
  "upstream": "https://github.com/sharkdp/fd/releases/tag/v10.2.0",
  "provides": ["fd"],
  "targets": {
    "linux-arm64": {
      "tier": "static",
      "status": "ga",
      "entry": "bin/fd",
      "paths": ["bin"],
      "size_budget_mb": 6,
      "smoke": "fd --version"
    },
    "ios-arm64": {
      "tier": "macho",
      "status": "ga",
      "entry": "bin/fd",
      "paths": ["bin"],
      "size_budget_mb": 6,
      "smoke": "fd --version"
    }
  }
}
```

Required: `id`, `version`, `license`, `method` (`source`, `prebuilt`, `repack`),
`upstream`. Each target block needs `status`, `tier`, `entry`, `size_budget_mb`,
`smoke`. `status` is one of `ga`, `experimental`, `planned`, `not-supported`;
`planned` entries are skipped by CI, `not-supported` entries must say why in
`notes` — an unexplained gap is a bug in this repo.

2. **`recipes/<id>.sh`** — a POSIX shell script. Header line one is
   `# deps: <packages>`, which `make deps` and CI read.

```sh
#!/bin/sh
# deps: cargo
# fd — a fast find. Ships as one binary, no config, no colours on by default.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/sharkdp/fd/archive/refs/tags/v$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/fd"
cd "$SB_WORK/src/fd/fd-$SB_VERSION"

cargo build --release --target "$(sb_rust_target)"
sb_bin "target/$(sb_rust_target)/release/fd" fd

SB_PATHS="bin"
SB_ENTRY="bin/fd"
sb_finish
```

3. **nothing else.** CI picks the tool up from the manifest, builds it per
   target, runs the smoke command in a clean environment, and enforces the size
   budget and the tier claim.

## Rules the recipes follow

* **`sb_init` first, `sb_finish` last.** Nothing else is mandatory, but every
  staged tree must end with `.sb/meta.json`, which `sb_meta` writes.
* **No absolute paths.** Everything a tool needs at run time lives under
  `$SB_BUNDLE_ROOT`. `CMAKE_ROOT`, `GOROOT`, `JAVA_HOME`, `THEOS` are set by
  `SB_ENV` with `${ROOT}` expansion.
* **Version comes from the manifest**, never hard-coded in the recipe. `$SB_VERSION`
  is already set.
* **Pin the source.** Tags, not `master`; a checksum in `sb_fetch` where upstream
  publishes one. `dist/provenance.json` records what was actually used.
* **Own your tier.** If the build cannot produce a zero-`DT_NEEDED` ELF, say
  `sfx` in the manifest. `verify.sh` fails the build either way; the difference is
  whether a human has to read the log.
* **Trim aggressively and document the trim.** Every `rm -rf` in a recipe is a
  size decision that a future reader will wonder about; put the reason in a
  comment, and put the budget in the manifest.
* **Keep the smoke test cheap.** `--version` is enough for 90% of tools; the other
  10% need a real invocation (`clang` compiles and runs a two-line C file, `python`
  imports `ssl` and `sqlite3`).

## Testing a recipe without CI

```sh
make tools/fd TARGET=linux-arm64 JOBS=4
sh scripts/verify.sh dist/fd-10.2.0-linux-arm64
./dist/fd-10.2.0-linux-arm64 --sb-print-meta
./dist/fd-10.2.0-linux-arm64 --sb-extract-dir /tmp/fd-tree
```

`--sb-extract-dir` is the fastest way to see what a bundle actually contains
without waiting for an exec, and it is how `verify.sh` inspects a payload.

## Adding a target

Add it to `manifest/targets`, to the `case "$SB_TARGET"` block at the top of
`recipes/_common.sh`, and to `TARGETS` in `scripts/matrix.py`. Recipes that can
not build it must say `not-supported` with a reason, or `planned` — silence is
not an option.
