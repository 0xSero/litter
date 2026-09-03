#!/usr/bin/env bash
# Validate that the ARM64 guest vdso embedded by litter-ish is a real aarch64
# ELF rather than the empty placeholder that litter-ish's
# vdso/arm64/meson.build creates when it cannot find an lld-capable clang
# (e.g. only Apple's clang on PATH). An empty vdso makes the app SIGABRT at
# launch as soon as a guest process hits a signal, so the build must fail
# loudly instead of silently shipping a broken embed.
#
# Usage: check-ish-vdso.sh <cargo-target-dir> <rust-target-triple> <profile>
set -euo pipefail

CARGO_TARGET_DIR="${1:?missing cargo target dir}"
TRIPLE="${2:?missing rust target triple}"
PROFILE="${3:?missing cargo profile}"

install_hint() {
  case "$(uname -s)" in
    Darwin)
      echo "install LLVM's clang and lld, then rebuild: brew install llvm lld"
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo "install clang and lld, then rebuild: apt-get install clang lld"
      elif command -v dnf >/dev/null 2>&1; then
        echo "install clang and lld, then rebuild: dnf install clang lld"
      else
        echo "install an lld-capable clang (clang + lld) and rebuild"
      fi
      ;;
    *)
      echo "install an lld-capable clang (clang + lld) and rebuild"
      ;;
  esac
}

HINT="$(install_hint)"

# Build-script outputs live under <target>/<triple>/<profile>/build/ for
# custom profiles, but historically landed at <target>/<triple>/build/. Search
# both layouts so the check is resilient to cargo layout changes.
VDSO_DIR=""
for base in \
  "$CARGO_TARGET_DIR/$TRIPLE/$PROFILE/build" \
  "$CARGO_TARGET_DIR/$TRIPLE/build"
do
  VDSO_DIR="$(find "$base" -type d -path "*ish-embed-host-*/out/meson-build/vdso/arm64" 2>/dev/null | head -n 1 || true)"
  [ -n "$VDSO_DIR" ] && break
done

if [ -z "$VDSO_DIR" ]; then
  # No embed build output for this target/profile (e.g. cleaned cache). The
  # stub degradation always leaves the meson build dir behind, so there is
  # nothing to validate here.
  exit 0
fi

VDSO="$VDSO_DIR/libvdso.so.elf"
if [ ! -f "$VDSO" ] || [ ! -s "$VDSO" ]; then
  echo "ERROR: iSH ARM64 vdso is missing or empty at $VDSO" >&2
  echo "       litter-ish's vdso/arm64/meson.build builds an empty stub when it cannot find" >&2
  echo "       an lld-capable clang; $HINT" >&2
  exit 1
fi

VDSO_KIND="$(file -b "$VDSO")"
case "$VDSO_KIND" in
  *"ELF 64-bit"*"ARM aarch64"*) ;;
  *)
    echo "ERROR: iSH ARM64 vdso at $VDSO is not an aarch64 ELF: $VDSO_KIND" >&2
    echo "       The app will SIGABRT at launch when a guest process hits a signal; $HINT" >&2
    exit 1
    ;;
esac

echo "==> iSH ARM64 vdso OK ($(stat -f '%z' "$VDSO") bytes, $VDSO_KIND)"
