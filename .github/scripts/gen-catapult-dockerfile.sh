#!/usr/bin/env bash
#
# gen-catapult-dockerfile.sh
#
# Emit a single multi-stage Dockerfile that builds catapult-server using UPSTREAM's own
# compiler + dependency build, then adds the nemtus packaging stages.
#
# WHY
# ---
# The hand-written client/catapult/Dockerfile.selfcontained reimplemented the dependency
# build (jenkins/catapult/installDepsLocal.py) and then flattened each dependency's own
# prefix into one directory. That flattening encoded a layout assumption, and the
# assumption broke silently: upstream's script installs OpenSSL with `--libdir` equal to
# the prefix, so libcrypto.so* sits flat in <prefix> while the copy globbed
# `<prefix>/lib*/`. It matched nothing, `|| true` hid it, and the image only worked
# because catapult happened to need the same SONAME the distro's openssl provides. The
# OpenSSL 3 -> 4 bump ended that coincidence and every binary started exiting 127.
#
# Upstream never hits this class of bug because upstream does not move libraries at all:
# baseImageDockerfileGenerator.py installs each dependency where the build consumes it
# and uses the resulting image directly. This script adopts that build verbatim, so
# upstream's choices arrive by FOLLOWING upstream instead of by us re-deriving them.
#
# INHERITED FROM UPSTREAM (no nemtus-side value to maintain)
#   OS release, all dependency versions ... jenkins/catapult/versions.properties
#   compiler family / version / STL ....... jenkins/catapult/compilers/gcc-latest.yaml
#   dependency install locations .......... baseImageDockerfileGenerator.py
#   C++ standard and build flags .......... same
#
# The ONLY value nemtus fixes is the target architecture, in
# .github/catapult/compiler-amd64.yaml, which documents why.
#
# WHY ONE FILE INSTEAD OF A CHAIN OF IMAGES
# -----------------------------------------
# Upstream builds these as four images, each `FROM` the previous one by registry tag
# (symbolplatform/...). Reproducing that here would be actively dangerous: the workflow
# builds with buildx's docker-container driver, which does NOT read the local image
# store, so `FROM symbolplatform/...` would be PULLED FROM DOCKER HUB — silently building
# against upstream's published image, which is the one thing this image must not do.
# Rewriting each layer's FROM to the preceding stage removes the registry entirely and
# keeps everything in one `docker buildx build`, cache and attestations intact.
#
# THE OUTPUT IS A BUILD ARTIFACT, NOT A SOURCE FILE
# -------------------------------------------------
# It is generated on every build rather than committed, which is the point: a committed
# copy would freeze upstream's values until someone regenerated it, recreating the drift
# this replaces. The workflow uploads the generated file and prints the inherited values
# to the run summary so a change in upstream's build is still visible in review.
#
# USAGE
#   gen-catapult-dockerfile.sh [--compiler-configuration <path>] [--out <path>]
#                              [--summary <path>]
#
# Defaults to .github/catapult/compiler-amd64.yaml and stdout. `--summary` writes a
# markdown table of the values taken from upstream, so callers can surface them without
# re-parsing the generated file (the values are also repeated as comments inside it).
# Needs python3 + PyYAML (ubuntu runners: python3-yaml).
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
compiler_configuration="${repo_root}/.github/catapult/compiler-amd64.yaml"
out=''
summary=''

while [ "$#" -gt 0 ]; do
	case "$1" in
		--compiler-configuration) compiler_configuration="$2"; shift 2 ;;
		--out) out="$2"; shift 2 ;;
		--summary) summary="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

jenkins_dir="${repo_root}/jenkins/catapult"
generator="${jenkins_dir}/baseImageDockerfileGenerator.py"
versions="${jenkins_dir}/versions.properties"
compiler_dockerfile="${jenkins_dir}/compilers/ubuntu-gcc/Dockerfile"

for f in "${generator}" "${versions}" "${compiler_dockerfile}" "${compiler_configuration}"; do
	[ -f "${f}" ] || { echo "::error::required input missing: ${f}" >&2; exit 1; }
done

# Read upstream's own values rather than hardcoding them. The compiler image selects gcc
# via COMPILER_VERSION, and the runtime stage must use the same Ubuntu release as the
# build stages or libstdc++ ABI can differ.
compiler_version="$(
	cd "${jenkins_dir}" && PYTHONPATH=. python3 -c "
import sys
from configuration import load_compiler_configuration
print(load_compiler_configuration(sys.argv[1]).compiler.version)
" "${compiler_configuration}"
)"
architecture="$(
	cd "${jenkins_dir}" && PYTHONPATH=. python3 -c "
import sys
from configuration import load_compiler_configuration
print(load_compiler_configuration(sys.argv[1]).architecture)
" "${compiler_configuration}"
)"
ubuntu_version="$(sed -n 's/^ubuntu[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "${versions}" | head -n1)"

for pair in "compiler_version=${compiler_version}" "architecture=${architecture}" "ubuntu_version=${ubuntu_version}"; do
	[ -n "${pair#*=}" ] || { echo "::error::could not read ${pair%%=*} from upstream's configuration" >&2; exit 1; }
done

# The compiler Dockerfile hardcodes its own `FROM ubuntu:X`. If that ever disagrees with
# versions.properties, the runtime stage would be built on a different release than the
# binaries — a silent ABI mismatch. Fail instead of guessing which one is right.
compiler_from_ubuntu="$(sed -n '1s|^FROM ubuntu:\(.*\)$|\1|p' "${compiler_dockerfile}")"
if [ "${compiler_from_ubuntu}" != "${ubuntu_version}" ]; then
	echo "::error::upstream disagrees with itself: ${compiler_dockerfile} is FROM ubuntu:${compiler_from_ubuntu} but versions.properties says ubuntu = ${ubuntu_version}. Resolve before building; picking either silently risks a libstdc++ ABI mismatch between the build and runtime stages." >&2
	exit 1
fi

gen_layer() {
	(cd "${jenkins_dir}" && PYTHONPATH=. python3 "${generator}" \
		--layer "$1" \
		--operating-system ubuntu \
		--compiler-configuration "${compiler_configuration}" \
		--versions "${versions}")
}

# Replace a fragment's single leading FROM with a stage reference. Asserts the shape
# rather than trusting it: if upstream's generator ever emits a fragment that does not
# start with exactly one FROM, a blind `sed 1s` would leave a Dockerfile that still pulls
# from Docker Hub — the exact failure this script exists to prevent.
restage() {
	local fragment="$1" from="$2" as="$3" count
	count="$(printf '%s\n' "${fragment}" | grep -c '^FROM ' || true)"
	if [ "${count}" != 1 ]; then
		echo "::error::expected exactly 1 FROM in upstream's '${as}' layer, found ${count}; the generator's output shape changed and the stage rewrite is no longer safe." >&2
		exit 1
	fi
	if ! printf '%s\n' "${fragment}" | head -n1 | grep -q '^FROM '; then
		echo "::error::upstream's '${as}' layer does not START with FROM; refusing to rewrite." >&2
		exit 1
	fi
	printf 'FROM %s AS %s\n' "${from}" "${as}"
	printf '%s\n' "${fragment}" | tail -n +2
}

layer_os="$(gen_layer os)"
layer_boost="$(gen_layer boost)"
layer_deps="$(gen_layer deps)"

emit() {
	cat <<EOF
# syntax=docker/dockerfile:1.7
#
# GENERATED by .github/scripts/gen-catapult-dockerfile.sh — DO NOT EDIT, DO NOT COMMIT.
#
# Stages 1-4 are upstream symbol/symbol's own compiler and dependency build, taken
# verbatim from jenkins/catapult, with each layer's FROM rewritten to the preceding stage
# so nothing is pulled from Docker Hub. Stages 5-6 are the nemtus packaging layers.
#
# Values inherited from upstream for this build:
#   ubuntu        ${ubuntu_version}      (versions.properties)
#   compiler      gcc ${compiler_version}      (compilers/gcc-latest.yaml)
#   dep versions  (versions.properties)
#   dep locations (baseImageDockerfileGenerator.py)
# Fixed by nemtus:
#   architecture  -march=${architecture}  (.github/catapult/compiler-amd64.yaml)

################### Stage 1: compiler (upstream, verbatim) ###################
EOF

	# Upstream's compiler Dockerfile is a complete file; adopt it as stage 1. Its
	# COMPILER_VERSION default is an older gcc, so override it with upstream's own
	# compiler definition. The ARG must come before the RUNs that consume it, and
	# upstream declares it mid-file, so re-declaring it here would be too late —
	# rewrite the existing declaration instead.
	awk -v ver="${compiler_version}" '
		NR == 1            { print $0 " AS compiler"; next }
		/^ARG COMPILER_VERSION=/ { print "ARG COMPILER_VERSION=" ver; next }
		                   { print }
	' "${compiler_dockerfile}"

	printf '\n################### Stage 2: os packages (upstream, generated) ###################\n'
	restage "${layer_os}" compiler preimage1

	printf '\n################### Stage 3: boost (upstream, generated) ###################\n'
	restage "${layer_boost}" preimage1 preimage2

	printf '\n################### Stage 4: native deps (upstream, generated) ###################\n'
	restage "${layer_deps}" preimage2 preimage3

	cat <<'BUILDER'

################### Stage 5: catapult build (nemtus) ###################
FROM preimage3 AS builder
USER root
ARG DEBIAN_FRONTEND=noninteractive

COPY client/catapult /src/client/catapult
WORKDIR /src/client/catapult

# Licensing gate baked into the build (defense in depth + automatic in-image evidence):
# the image cannot be built from a tree containing Tech Bureau Commercial-licensed files,
# and the PASS report travels with the image as proof the gate held at build time. Placed
# BEFORE cmake so a source-scope violation fails fast without an expensive build.
RUN set -eu; \
    mkdir -p /opt/catapult/licenses; \
    if bash scripts/check-license-scope.sh > /opt/catapult/licenses/LICENSE-SCOPE-REPORT.txt 2>&1; then \
        cat /opt/catapult/licenses/LICENSE-SCOPE-REPORT.txt; \
    else \
        cat /opt/catapult/licenses/LICENSE-SCOPE-REPORT.txt; exit 1; \
    fi

# catapult's CMakeLists.txt requires a .git at the repo root (../../.git) and derives its
# version string from `git`. We copy only subtrees (not the monorepo .git) to keep the
# build context small, so synthesize a minimal repo that satisfies both. Kept
# DETERMINISTIC and independent of VCS_REF on purpose: this layer sits above the
# expensive cmake/ninja layer, so a changing ref here would bust the compile cache on
# every commit. The true source revision travels in the runtime stage's OCI
# image.revision label instead.
RUN cd /src && git init -q -b dev \
    && git -c user.email=build@nemtus.invalid -c user.name=nemtus-build \
           commit -q --allow-empty -m "self-contained build"

# BOOST_ROOT and OPENSSL_ROOT_DIR are upstream's own install locations from stages 3 and
# 4, not nemtus choices. USE_CONAN defaults to OFF, so this is the manual build path with
# no conan remote.
RUN mkdir _build && cd _build \
    && BOOST_ROOT=/mybuild cmake .. \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DOPENSSL_ROOT_DIR=/usr/catapult/deps \
        -GNinja \
    && ninja -j"$(nproc)"

# --- collect artifacts + the libraries they actually need --------------------------
# Delegated to the same script the non-generated path uses, so there is one definition
# and one test. It derives the bundled set from the artifacts' own ELF NEEDED entries,
# transitively, and locates each wherever upstream installed it — which matters here
# because upstream spreads dependencies across /usr/catapult/deps (OpenSSL), /mybuild
# (boost) and /usr (mongo, zeromq, rocksdb), and that last one interleaves with the
# distro's own libraries. See the script header: five separate bugs came from trying to
# encode those locations instead of asking.
#
# Copied in its own layer AFTER the compile so editing it does not invalidate the compile.
COPY .github/catapult/scripts/stage-runtime-tree.sh /opt/nemtus/stage-runtime-tree.sh
# Upstream's three install locations, all passed explicitly: OpenSSL goes to
# /usr/catapult/deps (flat, --libdir equals the prefix), boost to /mybuild, and
# mongo/zeromq/rocksdb to /usr via -DCMAKE_INSTALL_PREFIX. That last one puts
# dependencies in the SYSTEM library path, which is why the script decides what is
# distro-provided by package OWNERSHIP (dpkg) rather than by location.
RUN bash /opt/nemtus/stage-runtime-tree.sh \
        --deps-dir /usr/catapult/deps \
        --deps-dir /mybuild \
        --deps-dir /usr/lib/x86_64-linux-gnu \
        --deps-dir /usr/lib
BUILDER

	cat <<EOF

################### Stage 6: runtime (nemtus) ###################
# Same Ubuntu release as the build stages (upstream's versions.properties), so the
# libstdc++ the binaries were compiled against is the one they run against.
FROM ubuntu:${ubuntu_version} AS runtime
EOF

	cat <<'RUNTIME'
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Minimal runtime: only the C++/atomic runtime libs and CA certificates. Everything
# catapult-specific was built in the stages above and is copied below.
# Recent ubuntu images already ship a non-root user at UID 1000, so reuse it (creating
# another UID 1000 would fail); only create one if the image happens not to have it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 libatomic1 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && if ! getent passwd 1000 >/dev/null; then useradd --uid 1000 -ms /bin/bash catapult; fi

COPY --from=builder /opt/catapult /opt/catapult

# Provenance / licensing metadata (OCI image-spec annotations). image.source +
# image.revision give the corresponding-source pointer required for LGPL-3.0
# redistribution; the full third-party inventory is bundled at
# /opt/catapult/licenses/THIRD_PARTY_NOTICES.md.
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="catapult-server" \
      org.opencontainers.image.description="Symbol catapult server (built from upstream's own dependency layers; no upstream prebuilt image or conan remote)" \
      org.opencontainers.image.vendor="nemtus" \
      org.opencontainers.image.source="https://github.com/nemtus/symbol" \
      org.opencontainers.image.url="https://github.com/nemtus/symbol/tree/dev/client/catapult" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VCS_REF}" \
      org.opencontainers.image.licenses="LGPL-3.0-or-later" \
      org.opencontainers.image.documentation="https://github.com/nemtus/symbol/blob/dev/client/catapult/docs/PUBLISHING-COMPLIANCE.md"

ENV LD_LIBRARY_PATH=/opt/catapult/lib:/opt/catapult/deps
ENV PATH=/opt/catapult/bin:$PATH

# Verify the published image actually is what it claims to be: every binary resolves, and
# every library we bundled is the one that wins resolution. Same script the staging test
# exercises; see its header for the two failure modes it gates and why the second is not
# redundant with the first.
COPY .github/catapult/scripts/verify-runtime-links.sh /tmp/verify-runtime-links.sh
RUN sh /tmp/verify-runtime-links.sh && rm -f /tmp/verify-runtime-links.sh
RUNTIME
}

if [ -n "${summary}" ]; then
	cat > "${summary}" <<EOF
| value | setting | source |
|---|---|---|
| Ubuntu release | \`${ubuntu_version}\` | upstream \`jenkins/catapult/versions.properties\` |
| compiler | \`gcc ${compiler_version}\` | upstream \`jenkins/catapult/compilers/gcc-latest.yaml\` |
| dependency versions | (boost, OpenSSL, mongo, zeromq, rocksdb …) | upstream \`jenkins/catapult/versions.properties\` |
| dependency install locations | — | upstream \`jenkins/catapult/baseImageDockerfileGenerator.py\` |
| target architecture | \`-march=${architecture}\` | **nemtus** \`.github/catapult/compiler-amd64.yaml\` |
EOF
fi

if [ -n "${out}" ]; then
	emit > "${out}"
	echo "wrote ${out} (ubuntu ${ubuntu_version}, gcc ${compiler_version}, -march=${architecture})"
else
	emit
fi
