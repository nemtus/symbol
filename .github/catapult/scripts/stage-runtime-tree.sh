#!/bin/sh
#
# stage-runtime-tree.sh — assemble /opt/catapult for the runtime image.
#
# Run inside the BUILDER stage, from the catapult source directory, after cmake/ninja.
# Copies the build outputs, the license texts, and every shared library the outputs
# actually need, into a clean tree the runtime stage can COPY wholesale.
#
# WHY THIS IS A SCRIPT AND NOT A `RUN` BLOCK
# ------------------------------------------
# It used to be inline in the Dockerfile. Four consecutive CI builds — about five and a
# half hours — were spent discovering four separate bugs in it, because the only way to
# run it was to compile catapult first. As a script it is exercised by
# test-runtime-staging.sh in seconds, against a fixture built from real build data.
#
# HOW THE LIBRARY SET IS DETERMINED
# ---------------------------------
# From what the artifacts ASK FOR (their ELF NEEDED entries), transitively, then located
# wherever upstream installed it. Every earlier approach encoded an assumption that turned
# out to be false:
#
#   1. Globbing <prefix>/lib*/*.so* assumed libraries live in a lib* SUBDIRECTORY.
#      Upstream's installDepsLocal.py gives OpenSSL `--libdir` equal to the prefix, so
#      libcrypto.so* is FLAT in /opt/deps/openssl. The glob matched nothing, `|| true`
#      hid it, and the image shipped having never bundled OpenSSL — it only worked while
#      catapult needed the same SONAME the distro provides, until 3 -> 4 ended that.
#   2. Requiring each dependency to yield a .so assumed each HAS one. `google`
#      (googletest + benchmark) is static and test-only: .a files and cmake config, no
#      .so. That turned a correct build into a failed one.
#   3. Deriving the set from `ldd` assumed the builder can RESOLVE these libraries. It
#      cannot — no LD_LIBRARY_PATH, no RPATH — so ldd printed "not found" and the stage
#      bundled nothing at all.
#   4. Reading NEEDED only from bin/ assumed the graph is one level deep. mongo's C++
#      drivers need mongo's C drivers, which nothing in bin/ names.
#
# `objdump -p` reads NEEDED out of the ELF header, so it needs no resolution and cannot
# quietly come back empty. `find` answers "where did upstream put it" with no layout
# knowledge. The loop repeats until the set stops growing, so the result is the transitive
# closure. A SONAME that cannot be located anywhere is reported BY NAME and fails.
#
# Usage: stage-runtime-tree.sh [--build-dir DIR] [--deps-dir DIR] [--dest DIR]
set -eu

build_dir=_build
deps_dirs=''
dest=/opt/catapult

while [ "$#" -gt 0 ]; do
	case "$1" in
		--build-dir) build_dir="$2"; shift 2 ;;
		# Repeatable: upstream spreads dependencies over several prefixes (OpenSSL in
		# /usr/catapult/deps, boost in /mybuild, mongo/zeromq/rocksdb in /usr), so a
		# single search root is not enough.
		--deps-dir) deps_dirs="${deps_dirs} $2"; shift 2 ;;
		--dest) dest="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ -n "${deps_dirs}" ] || deps_dirs=/opt/deps

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${dest}/bin" "${dest}/lib" "${dest}/deps" "${dest}/resources" "${dest}/licenses"

# Build outputs. catapult emits its plugins as shared objects into _build/bin alongside
# the executables, so bin/ legitimately holds both; the runtime stage puts bin/ on
# LD_LIBRARY_PATH for that reason. There is no _build/lib in practice, but copy it when
# present rather than assuming either way.
cp -aL "${build_dir}"/bin/* "${dest}/bin/"
if [ -d "${build_dir}/lib" ]; then
	cp -aL "${build_dir}"/lib/*.so* "${dest}/lib/" 2>/dev/null || true
fi
cp -aL resources/* "${dest}/resources/" 2>/dev/null || true

# License texts travel with the image so it is self-describing for LGPL-3.0
# redistribution (license + corresponding-source pointer).
cp -aL COPYING.LESSER "${dest}/licenses/LGPL-3.0.txt"
cp -aL LICENSE.txt "${dest}/licenses/LICENSE.txt"
cp -aL THIRD_PARTY_NOTICES.md "${dest}/licenses/THIRD_PARTY_NOTICES.md"

# SONAMEs the base image's own packages provide. Bundling these would shadow the distro's,
# which is the opposite of what we want.
#
# DECIDED BY PACKAGE OWNERSHIP, NOT BY NAME AND NOT BY LOCATION. Two earlier shapes of
# this test were wrong:
#
#   - A hand-written name list. glibc alone ships libc, libm, libdl, librt, libpthread,
#     libresolv, libnss_*, libanl … and the one that was missing — libresolv.so.2,
#     reached transitively through mongo's C driver — failed a correct build after an
#     hour. Enumerating another project's package contents by hand is the same mistake as
#     hardcoding its install layout.
#   - `ldconfig -p`. Better, but it answers "is this on the loader path", which is not the
#     same question. Upstream installs mongo, zeromq and rocksdb with
#     `-DCMAKE_INSTALL_PREFIX=/usr`, i.e. INTO the system library path, so those would be
#     classified as distro-provided and silently left out of the image.
#
# `dpkg -S` answers the actual question: does a package own this file? A dependency built
# from source does not, wherever it was installed. That makes the test independent of
# both naming and layout, which is the property every earlier version lacked.
# Overridable so the test can exercise the "ownership unavailable" path without needing
# a PATH that has a shell but no dpkg.
DPKG="${DPKG:-dpkg}"
if ! command -v "${DPKG}" >/dev/null 2>&1; then
	echo "ERROR: dpkg is unavailable, so package ownership cannot be determined." >&2
	echo "       Refusing to guess which libraries the base image provides." >&2
	exit 1
fi

# Memoised: dpkg -S is a database lookup and the same SONAME recurs across 148 objects.
is_distro_provided() {
	_soname="$1"
	if grep -Fxq "${_soname}" "${work}/distro" 2>/dev/null; then return 0; fi
	if grep -Fxq "${_soname}" "${work}/not-distro" 2>/dev/null; then return 1; fi

	# Resolve the SONAME to a path the way the loader would, then ask who owns it.
	_path="$(ldconfig -p 2>/dev/null \
		| sed -n "s|^[[:space:]]*${_soname} .*=> \(/[^[:space:]]*\)$|\1|p" | head -n1)"
	if [ -n "${_path}" ] && "${DPKG}" -S "${_path}" >/dev/null 2>&1; then
		echo "${_soname}" >> "${work}/distro"
		return 0
	fi
	echo "${_soname}" >> "${work}/not-distro"
	return 1
}

# Already in the tree? Covers both previously staged dependencies and catapult's own
# libcatapult.* / libextension.*, which bin/ already holds. Deliberately a presence test
# rather than a name pattern: a renamed or relocated build output cannot slip through.
already_present() {
	[ -e "${dest}/deps/$1" ] || [ -e "${dest}/lib/$1" ] || [ -e "${dest}/bin/$1" ]
}

: > "${work}/scanned"
: > "${work}/missing"
: > "${work}/seen-needed"
round=0
while :; do
	round=$((round + 1))
	# Only a backstop against a pathological cycle hanging a 90-minute build; the
	# closure settles in two or three rounds.
	if [ "${round}" -gt 20 ]; then
		echo "ERROR: dependency closure did not settle in 20 rounds" >&2
		exit 1
	fi

	: > "${work}/todo"
	for f in "${dest}"/bin/* "${dest}"/lib/* "${dest}"/deps/*; do
		[ -f "${f}" ] || continue
		grep -Fxq "${f}" "${work}/scanned" && continue
		echo "${f}" >> "${work}/scanned"
		objdump -p "${f}" 2>/dev/null | awk '/NEEDED/ { print $2 }' >> "${work}/todo" || true
	done
	[ -s "${work}/todo" ] || break
	cat "${work}/todo" >> "${work}/seen-needed"

	sort -u "${work}/todo" > "${work}/todo.u"
	while read -r soname; do
		is_distro_provided "${soname}" && continue
		already_present "${soname}" && continue
		src=''
		for d in ${deps_dirs}; do
			[ -d "${d}" ] || continue
			src="$(find "${d}" -name "${soname}" \( -type f -o -type l \) -print -quit 2>/dev/null)"
			[ -n "${src}" ] && break
		done
		if [ -z "${src}" ]; then
			echo "${soname}" >> "${work}/missing"
			continue
		fi
		cp -aL "${src}" "${dest}/deps/"
	done < "${work}/todo.u"
done

if [ ! -s "${work}/scanned" ]; then
	echo "ERROR: no artifacts were scanned under ${dest}; the build output is not what we expect" >&2
	exit 1
fi

# Scanning files is not the same as reading anything out of them. If objdump is missing,
# or silently fails, or the artifacts are not ELF, the loop above completes having
# collected no NEEDED at all — and would then report an empty bundle as success. That is
# how an earlier version of this step shipped an image bundling ZERO libraries. catapult
# links against boost, OpenSSL, mongo, zeromq and rocksdb, so "nothing is needed" is never
# a true answer here.
if [ ! -s "${work}/seen-needed" ]; then
	echo "ERROR: scanned $(wc -l < "${work}/scanned" | tr -d ' ') objects under ${dest} but found no NEEDED entries in any of them." >&2
	echo "       catapult always links shared libraries, so this means objdump is unavailable or the" >&2
	echo "       artifacts are not the ELF objects we expect — not that there is nothing to bundle." >&2
	exit 1
fi

if [ -s "${work}/missing" ]; then
	echo "ERROR: these SONAMEs are required (directly or transitively) but were not found under any of:${deps_dirs}" >&2
	sort -u "${work}/missing" | sed 's/^/  /' >&2
	exit 1
fi

ls -1 "${dest}/deps" | sed 's/^/bundled: /'
echo "classified $(wc -l < "${work}/distro" 2>/dev/null | tr -d ' ') SONAMEs as distro-provided (dpkg-owned)"
echo "staged $(ls -1 "${dest}/bin" | wc -l | tr -d ' ') artifacts and $(ls -1 "${dest}/deps" | wc -l | tr -d ' ') bundled libraries"
