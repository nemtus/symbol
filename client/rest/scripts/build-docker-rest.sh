#!/usr/bin/env bash
#
# Build the nemtus symbol-rest Docker image (client/rest/Dockerfile.nemtus).
#
# The build context is client/rest (the same as the upstream Dockerfile). The image
# runs the license-scope gate at build time and bundles the result + license texts.
#
# Usage:
#   client/rest/scripts/build-docker-rest.sh
#
# Environment overrides:
#   IMAGE           image tag to build        (default: nemtus/symbol-rest:local)
#   UBUNTU_VERSION  base ubuntu image version (default: image default, 24.04)
#   NODE_MAJOR      Node.js major version     (default: image default, 24)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"        # client/rest
REPO_ROOT="$(cd "${REST_DIR}/../.." && pwd)"      # repo root (for the VCS ref)

IMAGE="${IMAGE:-nemtus/symbol-rest:local}"

# Provenance: the image records the exact source revision in its OCI image.revision
# label. Derive it from the host checkout; mark a dirty working tree so an image built
# from uncommitted changes is not mistaken for a clean commit.
VCS_REF="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "${REPO_ROOT}" diff --quiet HEAD 2>/dev/null; then
	VCS_REF="${VCS_REF}-dirty"
fi

build_args=(--build-arg "VCS_REF=${VCS_REF}" --build-arg "IMAGE_VERSION=${IMAGE_VERSION:-local}")
[[ -n "${UBUNTU_VERSION:-}" ]] && build_args+=(--build-arg "UBUNTU_VERSION=${UBUNTU_VERSION}")
[[ -n "${NODE_MAJOR:-}" ]] && build_args+=(--build-arg "NODE_MAJOR=${NODE_MAJOR}")

echo "[*] context : ${REST_DIR}"
echo "[*] image   : ${IMAGE}"
echo "[*] vcs ref : ${VCS_REF}"

cd "${REST_DIR}"
DOCKER_BUILDKIT=1 docker build \
	-f Dockerfile.nemtus \
	-t "${IMAGE}" \
	"${build_args[@]}" \
	.

echo "[*] done. verify the image with:"
echo "    docker run --rm ${IMAGE} --check src/index.js          # syntax-load the entrypoint"
echo "    docker run --rm --entrypoint sh ${IMAGE} -c 'ls /app/licenses'"
