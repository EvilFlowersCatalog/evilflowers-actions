#!/usr/bin/env bash
# Contract test of .github/actions/resolve-worker/resolve-worker.sh against the real evilflowers-worker repository:
# a throwaway consumer on branch = "master" is resolved as a develop build, a main build and a KIT_REF hold.
# Needs git, uv and network access. Run from anywhere: tests/resolve-worker.sh
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/resolve-worker/resolve-worker.sh"
kit_url="${KIT_URL:-https://github.com/EvilFlowersCatalog/evilflowers-worker}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

consumer() { # $1 = directory
  mkdir -p "$1"
  cat > "$1/pyproject.toml" <<EOF
[project]
name = "consumer"
version = "0"
requires-python = ">=3.12"
dependencies = ["evilflowers-worker"]

[tool.uv.sources]
evilflowers-worker = { git = "${kit_url}", branch = "master" }
EOF
}

# resolve <case> <GITHUB_REF> <KIT_REF> → sets $ref and $rev from the step outputs, as Actions would read them.
# A real GITHUB_OUTPUT file: on Linux, appending to /dev/stdout of a redirected run reopens the file, and the
# script's later output overwrites what was appended.
resolve() {
  local dir="$work/$1"
  consumer "$dir"
  : > "$dir/github_output"
  if ! env GITHUB_OUTPUT="$dir/github_output" GITHUB_REF="$2" KIT_REF="$3" PROJECT_DIR="$dir" \
    bash "$script" > "$dir/log" 2>&1; then
    cat "$dir/log" >&2
    fail "$1: the script failed"
  fi
  ref=$(sed -n 's/^ref=//p' "$dir/github_output")
  rev=$(sed -n 's/^revision=//p' "$dir/github_output")
}

expect() { # <case> <want ref> <want revision>
  if [ "$ref" != "$2" ] || [ "$rev" != "$3" ]; then
    fail "$1: got '$ref $rev', want '$2 $3'"
  fi
}

master=$(git ls-remote "$kit_url" refs/heads/master | cut -f1)
newest=$(git ls-remote --tags --refs --sort=-version:refname "$kit_url" 'v*.*.*' \
  | cut -f2 | sed 's#^refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
if [ -z "$master" ] || [ -z "$newest" ]; then fail "cannot read the kit's master and tags"; fi
tag_commit() { git ls-remote "$kit_url" "refs/tags/$1^{}" "refs/tags/$1" | head -n1 | cut -f1; }

resolve develop refs/heads/develop ""
expect develop master "$master"
grep -q 'branch = "master"' "$work/develop/pyproject.toml" || fail "develop: pyproject.toml was rewritten"
echo "ok develop → master ${rev::7}"

resolve main refs/heads/main ""
expect main "$newest" "$(tag_commit "$newest")"
grep -q "tag = \"${newest}\"" "$work/main/pyproject.toml" || fail "main: pyproject.toml not on tag = \"$newest\""
echo "ok main → ${newest} ${rev::7}"

resolve hold refs/heads/develop v0.1.0
expect hold v0.1.0 "$(tag_commit v0.1.0)"
echo "ok KIT_REF=v0.1.0 on develop → v0.1.0 ${rev::7}"

# A consumer not on branch = "master" is refused, not silently left alone.
consumer "$work/pinned"
sed -i.bak 's/branch = "master"/rev = "eb1d19c"/' "$work/pinned/pyproject.toml"
if env -u GITHUB_OUTPUT GITHUB_REF=refs/heads/main KIT_REF="" PROJECT_DIR="$work/pinned" bash "$script" > /dev/null 2>&1; then
  fail "pinned: a source on rev = was accepted"
fi
echo "ok a pinned source fails a main build"
