#!/usr/bin/env bash
#
# Build the self-contained catapult-server Docker image.
#
# This wrapper resolves the repository root (the required build context) and runs
# the build for client/catapult/Dockerfile.selfcontained, which depends on NO
# upstream implicit assets: no symbolplatform/* base image and no conan.symbol.dev
# remote. All native dependencies are built from canonical upstream sources.
#
# Usage:
#   client/catapult/scripts/build-docker-selfcontained.sh
#
# Environment overrides:
#   IMAGE           image tag to build        (default: nemtus/catapult-server:local)
#   UBUNTU_VERSION  base ubuntu image version (default: image default, 25.10)
#
# Example:
#   IMAGE=nemtus/catapult-server:v1 UBUNTU_VERSION=24.04 \
#     client/catapult/scripts/build-docker-selfcontained.sh

set -euo pipefail

# Resolve repository root from this script's location (.../client/catapult/scripts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

IMAGE="${IMAGE:-nemtus/catapult-server:local}"
DOCKERFILE="client/catapult/Dockerfile.selfcontained"

# Provenance: the runtime image records the exact source revision in its OCI
# image.revision label. Derive it from the host checkout; mark a dirty working tree so
# an image built from uncommitted changes is not mistaken for a clean commit. Only the
# (cheap) runtime label consumes this, so it never busts the compile cache.
VCS_REF="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "${REPO_ROOT}" diff --quiet HEAD 2>/dev/null; then
	VCS_REF="${VCS_REF}-dirty"
fi

build_args=(--build-arg "VCS_REF=${VCS_REF}")
if [[ -n "${UBUNTU_VERSION:-}" ]]; then
	build_args+=(--build-arg "UBUNTU_VERSION=${UBUNTU_VERSION}")
fi

echo "[*] repo root : ${REPO_ROOT}"
echo "[*] dockerfile: ${DOCKERFILE}"
echo "[*] image     : ${IMAGE}"
echo "[*] vcs ref   : ${VCS_REF}"

cd "${REPO_ROOT}"
DOCKER_BUILDKIT=1 docker build \
	-f "${DOCKERFILE}" \
	-t "${IMAGE}" \
	"${build_args[@]}" \
	.

# NOTE: the image ENTRYPOINT is catapult.server, so `docker run IMAGE <tool> ...`
# would pass <tool> to the server as a resources path. Run a tool by overriding the
# entrypoint instead.
echo "[*] done. verify the toolchain with:"
echo "    docker run --rm --entrypoint catapult.tools.addressgen ${IMAGE} --count 1"
