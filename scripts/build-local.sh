#!/bin/bash
# Build locally using the same stock manylinux Docker image as CI.
# Usage: ./scripts/build-local.sh [image] [build|clean|shell]
#   image - manylinux image name (default: manylinux_2_28_x86_64)
#
# Thin wrapper over edapack-common's local-build.sh (run `ivpm update -a` first
# so packages/edapack-common is present). Input versions (Verilator, Z3, ...)
# come from build-inputs.yaml; the tarball and manifest land in ./dist.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD="${EC_COMMON:-$ROOT/packages/edapack-common}/scripts/local-build.sh"

if [ ! -f "$LOCAL_BUILD" ]; then
    echo "ERROR: $LOCAL_BUILD not found; run 'ivpm update -a' or set EC_COMMON." >&2
    exit 1
fi

IMAGE_NAME="${1:-${IMAGE_NAME:-manylinux_2_28_x86_64}}" \
    exec bash "$LOCAL_BUILD" "$ROOT" "${2:-build}"
