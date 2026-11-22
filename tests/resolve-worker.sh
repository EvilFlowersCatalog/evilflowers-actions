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

# resolve <case> <GITHUB_REF> <KIT_REF> → prints "ref revision"
resolve() {
  local dir="$work/$1"
  consumer "$dir"
  env -u GITHUB_OUTPUT GITHUB_REF="$2" KIT_REF="$3" PROJECT_DIR="$dir" bash "$script" > "$dir/out" 2>&1 \
    || { cat "$dir/out" >&2; fail "$1: the script failed"; }
  printf '%s %s\n' "$(sed -n 's/^ref=//p' "$dir/out")" "$(sed -n 's/^revision=//p' "$dir/out")"
}

master=$(git ls-remote "$kit_url" refs/heads/master | cut -f1)
newest=$(git ls-remote --tags --refs --sort=-version:refname "$kit_url" 'v*.*.*' \
  | cut -f2 | sed 's#^refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
[ -n "$master" ] && [ -n "$newest" ] || fail "cannot read the kit's master and tags"
tag_commit() { git ls-remote "$kit_url" "refs/tags/$1^{}" "refs/tags/$1" | head -n1 | cut -f1; }

read -r ref rev < <(resolve develop refs/heads/develop "")
[ "$ref" = master ] && [ "$rev" = "$master" ] || fail "develop: got '$ref $rev', want 'master $master'"
grep -q 'branch = "master"' "$work/develop/pyproject.toml" || fail "develop: pyproject.toml was rewritten"
echo "ok develop → master ${rev::7}"

read -r ref rev < <(resolve main refs/heads/main "")
want=$(tag_commit "$newest")
[ "$ref" = "$newest" ] && [ "$rev" = "$want" ] || fail "main: got '$ref $rev', want '$newest $want'"
grep -q "tag = \"${newest}\"" "$work/main/pyproject.toml" || fail "main: pyproject.toml not on tag = \"$newest\""
echo "ok main → ${newest} ${rev::7}"

read -r ref rev < <(resolve hold refs/heads/develop v0.1.0)
want=$(tag_commit v0.1.0)
[ "$ref" = v0.1.0 ] && [ "$rev" = "$want" ] || fail "hold: got '$ref $rev', want 'v0.1.0 $want'"
echo "ok KIT_REF=v0.1.0 on develop → v0.1.0 ${rev::7}"

# A consumer not on branch = "master" is refused, not silently left alone.
consumer "$work/pinned"
sed -i.bak 's/branch = "master"/rev = "eb1d19c"/' "$work/pinned/pyproject.toml"
if env -u GITHUB_OUTPUT GITHUB_REF=refs/heads/main KIT_REF="" PROJECT_DIR="$work/pinned" bash "$script" > /dev/null 2>&1; then
  fail "pinned: a source on rev = was accepted"
fi
echo "ok a pinned source fails a main build"
