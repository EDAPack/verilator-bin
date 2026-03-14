#!/bin/bash
# Build locally using the same manylinux Docker image as CI.
# Usage: ./scripts/build-local.sh [image] [vlt_tag] [bwz_tag]
#   image   - manylinux image name (default: manylinux_2_28_x86_64)
#   vlt_tag - Verilator git tag or "master" (default: master)
#   bwz_tag - Bitwuzla release tag (default: latest from GitHub)

set -e

IMAGE="${1:-manylinux_2_28_x86_64}"
VLT_TAG="${2:-master}"

if test -z "$3"; then
    BWZ_TAG=$(curl -s -L \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/bitwuzla/bitwuzla/releases/latest \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
else
    BWZ_TAG="$3"
fi

echo "Image:     ${IMAGE}"
echo "Verilator: ${VLT_TAG}"
echo "Bitwuzla:  ${BWZ_TAG}"

docker run --rm \
    --volume "$(pwd):/io" \
    --env vlt_latest_rls="${VLT_TAG}" \
    --env bwz_latest_rls="${BWZ_TAG}" \
    --env image="${IMAGE}" \
    --workdir /io \
    "quay.io/pypa/${IMAGE}" \
    /io/scripts/build.sh
