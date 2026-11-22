#!/usr/bin/env bash
# Lock evilflowers-worker to the ref this build's branch follows, for this CI run only. Nothing is committed.
#
# Rule 2 of EvilFlowersCatalog/evilflowers-worker#13:
#
#   develop, PRs, other branches → the kit's `master` head (dev runs what will be released; the nightly
#                                  rebuilds when it moves)
#   main / master, tags          → the kit's newest release tag vX.Y.Z (prod only gets a released kit). No tag
#                                  found is an error, never a silent `master` (v0.1.0 exists since 2026-11-22).
#   KIT_REF=<ref>                → that ref: a hold on a known-good tag, or a test of a kit branch. In CI the
#                                  repository variable KIT_REF, which also pauses the nightly.
#
# When the ref is not `master`, [tool.uv.sources] in pyproject.toml is rewritten from branch = "master" to
# tag = "<ref>" (or branch = "<ref>" for another branch). Then `uv lock --upgrade-package evilflowers-worker`.
# The caller hands pyproject.toml + uv.lock to the image build (artifact), so the tested lock is the shipped one.
#
# Inputs (env): PROJECT_DIR (default .), KIT_REF, KIT_URL (default the GitHub repository), GITHUB_REF.
# Output ($GITHUB_OUTPUT, or stdout): ref (master | vX.Y.Z | <branch>), revision (the 40-hex commit uv.lock pins).
set -euo pipefail

cd "${PROJECT_DIR:-.}"
kit_url="${KIT_URL:-https://github.com/EvilFlowersCatalog/evilflowers-worker}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

ref="${KIT_REF:-}"
if [ -z "$ref" ]; then
  case "${GITHUB_REF:-}" in
    refs/heads/main | refs/heads/master | refs/tags/*)
      # Newest SemVer tag; peeled (^{}) lines and pre-releases (v1.2.0-rc1) are not releases.
      ref=$(git ls-remote --tags --refs --sort=-version:refname "$kit_url" 'v*.*.*' \
        | cut -f2 | sed 's#^refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
      if [ -z "$ref" ]; then
        echo "::error::no release tag v*.*.* found on ${kit_url}; ${GITHUB_REF} only builds on a released kit"
        exit 1
      fi
      ;;
    *) ref=master ;;
  esac
fi

if [ "$ref" != master ]; then
  grep -q 'evilflowers-worker = { git = .*, branch = "master" }' pyproject.toml \
    || { echo "::error::pyproject.toml: [tool.uv.sources] evilflowers-worker is not on branch = \"master\""; exit 1; }
  # uv's source keys are `tag` and `branch`.
  key=branch
  if git ls-remote --exit-code --tags "$kit_url" "refs/tags/$ref" > /dev/null; then key=tag; fi
  sed -i.bak -E "s#(evilflowers-worker = \{ git = \"[^\"]+\", )branch = \"master\"#\1${key} = \"${ref}\"#" pyproject.toml
  rm -f pyproject.toml.bak
fi

uv lock --upgrade-package evilflowers-worker
revision=$(grep -oE 'evilflowers-worker(\.git)?\?[^#"]*#[0-9a-f]{40}' uv.lock | head -n1 | cut -d'#' -f2 || true)
[ -n "$revision" ] || { echo "::error::no evilflowers-worker commit in uv.lock"; exit 1; }

{
  echo "ref=$ref"
  echo "revision=$revision"
} >> "$out"
echo "::notice::evilflowers-worker ${ref} = ${revision}"
