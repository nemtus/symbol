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
# Located by pattern, not by line number. The v1.0.3.9 tag's copy opens with a comment
# ("# use Ubuntu 25.10 to get gcc 14/15…") and has FROM on line 2, so assuming line 1
# broke security rebuilds of already-released tags — the one case where this script is
# pointed at an OLDER upstream tree than the one it was written against.
compiler_from_line="$(grep -n '^FROM ubuntu:' "${compiler_dockerfile}" | head -n1 | cut -d: -f1)"
if [ -z "${compiler_from_line}" ]; then
	echo "::error::no 'FROM ubuntu:<version>' line found in ${compiler_dockerfile}." >&2
	exit 1
fi
compiler_from_ubuntu="$(sed -n "${compiler_from_line}s|^FROM ubuntu:\(.*\)$|\1|p" "${compiler_dockerfile}")"
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
	awk -v ver="${compiler_version}" -v fromline="${compiler_from_line}" '
		NR == fromline            { print $0 " AS compiler"; next }
		/^ARG COMPILER_VERSION=/  { print "ARG COMPILER_VERSION=" ver; next }
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
# --- build + stage, BY UPSTREAM'S OWN SCRIPT ---------------------------------------
# runDockerBuildInnerBuild.py is what upstream runs to build catapult: it sets BOOST_ROOT
# and GTEST_ROOT, derives the whole cmake command line from the two configuration files,
# runs ninja and `ninja install`, and then copies the runtime dependencies into
# <out>/deps. Calling it means none of those decisions are re-derived here.
#
# Everything nemtus previously hand-wrote in this stage was wrong in some way that only
# showed up after a 90-minute build:
#
#   - The cmake invocation. Upstream passes -DENABLE_TESTS=OFF for a release, so GTest is
#     never needed; ours omitted that and failed with "Could NOT find GTest". It also
#     passes -DARCHITECTURE_NAME (which is how -march is set), plus
#     CATAPULT_BUILD_RELEASE / CATAPULT_BUILD_RELEASE_PUBLIC. Our nemtus architecture
#     choice reaches it as -DARCHITECTURE_NAME=<arch> with no extra wiring.
#   - The dependency staging. Upstream's copy_dependencies already knows the exact set,
#     including libbson2 / libmongoc2 (mongo's C drivers, named by nothing in bin/),
#     snappy and gflags (rocksdb's), OpenSSL's flat libdir — and `ossl-modules`, the
#     OpenSSL 4 provider directory, which is loaded by dlopen and so appears in NO ELF
#     NEEDED entry. A SONAME-based reimplementation cannot find it even in principle, and
#     an OpenSSL 4 build without its providers is a plausible cause of the SIGSEGV that
#     ended the hand-written path.
#
# `release-public` is upstream's own build configuration for a public release
# (disposition: public, use_conan: false, enable_diagnostics: false).
#
# PyYAML is what upstream's configuration loader needs. Installed at upstream's pinned
# version from jenkins/catapult/requirements.txt rather than from the distro, and with
# --break-system-packages because Ubuntu's system python is PEP 668 externally-managed.
# conan is in that file too but is not installed: use_conan is false here.
USER root
COPY jenkins/catapult /src/jenkins/catapult
# The compiler configuration resolves its `compiler:` path relative to its own
# grandparent directory, so it must sit at /src/.github/catapult for
# ../jenkins/catapult/compilers/gcc-latest.yaml to land on the copy above.
COPY .github/catapult/compiler-amd64.yaml /src/.github/catapult/compiler-amd64.yaml
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        "$(grep -E '^PyYAML==' /src/jenkins/catapult/requirements.txt)"

RUN PYTHONPATH=/src/jenkins/catapult python3 /src/jenkins/catapult/runDockerBuildInnerBuild.py \
        --compiler-configuration /src/.github/catapult/compiler-amd64.yaml \
        --build-configuration /src/jenkins/catapult/configurations/release-public.yaml \
        --source-path /src/client/catapult \
        --out-dir /opt/catapult

# LGPL-3.0 redistribution material. Not part of upstream's install target — upstream does
# not redistribute this image, nemtus does — so it is added here rather than re-derived
# inside upstream's script. The scope report was written before the build (above) and is
# already in place.
RUN set -eu; \
    cd /src/client/catapult; \
    cp -aL COPYING.LESSER /opt/catapult/licenses/LGPL-3.0.txt; \
    cp -aL LICENSE.txt /opt/catapult/licenses/LICENSE.txt; \
    cp -aL THIRD_PARTY_NOTICES.md /opt/catapult/licenses/THIRD_PARTY_NOTICES.md; \
    ls -1 /opt/catapult; \
    ls -1 /opt/catapult/deps | sed 's/^/dep: /'

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

# Both values are upstream's own, from runDockerBuild.py's image `--change` arguments:
#   ENV LD_LIBRARY_PATH="<home>/lib:<home>/deps"
#   ENV OPENSSL_MODULES="<home>/deps/ossl-modules"
#
# Note bin/ is deliberately NOT on the library path. The hand-written build needed it
# there because `cp -aL _build/bin/*` dumped catapult's plugin shared objects in with the
# executables; upstream's `ninja install` puts them in lib/, where they belong.
#
# OPENSSL_MODULES is the one that was missing entirely. OpenSSL 4 delegates algorithms to
# provider modules loaded by dlopen, so they appear in no ELF NEEDED entry and a
# SONAME-based dependency scan cannot discover them. An OpenSSL 4 build whose providers
# are absent is a plausible cause of the SIGSEGV the hand-written path ended on.
ENV LD_LIBRARY_PATH=/opt/catapult/lib:/opt/catapult/deps
ENV OPENSSL_MODULES=/opt/catapult/deps/ossl-modules
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
