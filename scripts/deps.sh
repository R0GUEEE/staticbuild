#!/bin/sh
# Install the packages a recipe declares in its first lines:
#
#   # deps: build-base cmake libplist-dev
#
#   deps.sh ninja          # one tool
#   deps.sh --all          # every buildable linux recipe (heavy, CI only)
#   deps.sh --print ninja  # just print the list
#
# On Alpine it uses apk, on Debian/Ubuntu apt-get, on macOS Homebrew. Parenthetical
# notes after a package name are stripped, so "# deps: cargo (or the rust bundle)"
# installs cargo. "(none)" means nothing to do.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

pkgcmd() {
  if command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew"
  else
    echo none
  fi
}

deps_of() {
  sed -n 's/^# deps:[[:space:]]*//p' "$ROOT/recipes/$1.sh" | head -1 |
    sed 's/([^)]*)//g' | tr -s ' ' '\n' | grep -v -E '^(none|)$' | sort -u
}

install() {
  pkgs=$1
  [ -n "$pkgs" ] || return 0
  case "$(pkgcmd)" in
    apk)  apk add --no-cache $pkgs ;;
    apt)  sudo apt-get update -qq && sudo apt-get install -y -qq $pkgs ;;
    brew) brew install $pkgs || true ;;
    none) echo "no package manager found; cannot install: $pkgs" >&2; return 1 ;;
  esac
}

case "${1:-}" in
  --print)
    deps_of "${2:?tool id required}"
    ;;
  --all)
    for r in "$ROOT"/recipes/*.sh; do
      t=$(basename "$r" .sh)
      case "$t" in _*) continue ;; esac
      d=$(deps_of "$t")
      [ -n "$d" ] && echo "==> $t: $d" >&2 && install "$d"
    done
    ;;
  *)
    [ $# -gt 0 ] || { echo "usage: deps.sh <tool> | --all | --print <tool>" >&2; exit 2; }
    install "$(deps_of "$1")"
    ;;
esac
