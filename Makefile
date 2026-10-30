# staticbuild — one file per tool.
#
#   make tools/ninja TARGET=linux-arm64
#   make all TARGET=linux-arm64
#   make verify
#   make matrix TARGET=ios-arm64
#
# Everything a recipe needs comes from the environment; the Makefile only
# sequences it and keeps the manifest as the single source of truth.

SHELL := /bin/sh
ROOT  := $(CURDIR)
TARGET ?= linux-arm64
DIST  ?= $(ROOT)/dist
JOBS  ?= 2

export SB_ROOT := $(ROOT)
export SB_DIST := $(DIST)
export SB_JOBS := $(JOBS)
export SB_TARGET := $(TARGET)

# version + tier come from the manifest so a bump is one edit
meta = python3 -c 'import json,sys; m=json.load(open("manifest/tools.json")); \
  t=[x for x in m["tools"] if x["id"]=="$(1)"][0]; \
  b=t.get("targets",{}).get("$(TARGET)",{}); \
  print(t["version"] if not b.get("version") else b["version"], b.get("tier","sfx"), sep="\t")'

TOOLS := $(shell python3 -c 'import json;print(" ".join(t["id"] for t in json.load(open("manifest/tools.json"))["tools"]))')

.PHONY: all clean distclean verify lint matrix stub deps help
# NB: the tools/* targets are deliberately NOT .PHONY. GNU make skips implicit
# rule search for phony targets, so `tools/%: FORCE` would never fire and every
# build would print "Nothing to be done". FORCE achieves the same "always run".

all: $(addprefix tools/,$(TOOLS))

tools/%: FORCE
	@set -eu; \
	  m=$$($(call meta,$*)); \
	  ver=$$(echo "$$m" | cut -f1); tier=$$(echo "$$m" | cut -f2); \
	  echo "--- $* $$ver ($(TARGET), $$tier)"; \
	  SB_VERSION="$$ver" SB_TIER="$$tier" SB_TOOL="$*" sh recipes/$*.sh

FORCE:

# Carrier stubs for every target this host can emit (build/stub/sb-stub-<target>).
stub:
	sh scripts/stub-build.sh

# The manifest is generated; `make manifest` rewrites it, `make check-manifest`
# fails when it is stale.
manifest:
	python3 tools/gen_manifest.py

check-manifest:
	python3 tools/gen_manifest.py --check

# Install the build dependencies a recipe declares in its header.
# Every recipe also needs: python3 (pack.py), zstd (payload), go (SFX stub).
deps:
	@for r in $(or $(TOOL),$(TOOLS)); do \
	  d=$$(sed -n 's/^# deps: //p' recipes/$$r.sh 2>/dev/null); \
	  echo "$$r: $${d:-none}"; \
	done

matrix:
	@python3 scripts/matrix.py --target $(TARGET) --pretty

verify:
	@python3 scripts/verify.py --all

lint: check-manifest
	@python3 scripts/matrix.py --check
	@python3 -m py_compile scripts/*.py tools/*.py && echo "python ok"
	@for f in recipes/*.sh scripts/*.sh; do sh -n "$$f" || exit 1; done && echo "shell ok"
	@if command -v shellcheck >/dev/null; then shellcheck -S warning recipes/*.sh scripts/*.sh; fi

clean:
	rm -rf build/stage build/llvm-out build/*.out

distclean: clean
	rm -rf dist build

help:
	@printf '%s\n' \
	  'make tools/<id> TARGET=<target>   build one tool' \
	  'make all TARGET=<target>          build the whole catalog for a target' \
	  'make matrix TARGET=<target>       print the CI matrix' \
	  'make lint                         manifest + shell + python checks' \
	  'make verify                       tier/budget/smoke every artifact' \
	  '' \
	  'targets: linux-{x86_64,arm64,armv7,386,riscv64}' \
	  '         windows-{x86_64,arm64,386}  macos-{arm64,x86_64,universal}' \
	  '         ios-{arm64,arm64-sim}     windows-universal' \
	  '  (scripts/matrix.py --list-targets prints them with tool counts)' \
	  'tools:' $(TOOLS)
