#!/usr/bin/env bash
set -euo pipefail

manifest="services/kittylitter/Cargo.toml"
version=$(awk -F'"' '/^version/ { print $2; exit }' "$manifest")

if [[ -z "$version" ]]; then
  echo "could not parse kittylitter version from $manifest" >&2
  exit 1
fi

tag="v$version"
if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  exit 0
fi

git fetch --no-tags --no-recurse-submodules origin "refs/tags/$tag:refs/tags/$tag"
if git diff --quiet "$tag" -- services/kittylitter; then
  exit 0
fi

echo "kittylitter source changed after $tag was released; bump the package version" >&2
exit 1
