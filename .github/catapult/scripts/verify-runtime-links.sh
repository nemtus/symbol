#!/bin/sh
#
# verify-runtime-links.sh — assert the image is actually loadable, and actually self-contained.
#
# Run inside the RUNTIME stage, after LD_LIBRARY_PATH is set and the distro packages are
# installed. That placement is the point: only there do the staged tree, the loader path
# and the distro's libraries coexist, which is the combination no earlier stage can check.
#
# Gates two distinct failure modes:
#
#   UNRESOLVED  A binary needs a library the image does not contain. Without this gate
#               the build goes green and every binary exits 127 on first run — which is
#               exactly how `libcrypto.so.4: cannot open shared object file` shipped.
#
#   SHADOWED    A library IS staged under the install prefix, but something resolves that
#               same SONAME from elsewhere (normally /usr/lib). That silently defeats the
#               point of a self-contained image: the binary runs against the distro's
#               build instead of the version upstream pins in CMakeLists.txt.
#
#               Not hypothetical, and not covered by the first check. For months the image
#               bundled no OpenSSL at all yet looked perfectly resolved to ldd, because
#               catapult needed the same SONAME the distro's openssl provides. Only when
#               upstream moved 3 -> 4 did the coincidence end.
#
# Only SONAMEs the image actually ships are checked, so libc / libstdc++ / libgcc_s /
# libatomic legitimately keep resolving to the distro.
#
# Findings accumulate in a file and each loop reads from a file rather than a pipe: no
# nested command substitution, no subshell to lose state in. This gates publishing, so it
# is written to be obvious rather than clever.
#
# Usage: verify-runtime-links.sh [--prefix DIR]
set -eu

prefix=/opt/catapult

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix) prefix="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Everything this image ships, by SONAME. bin/ is included because catapult's plugins are
# shared objects emitted alongside the executables.
ls "${prefix}/lib" "${prefix}/deps" "${prefix}/bin" 2>/dev/null \
	| grep -E '\.so' | sort -u > "${work}/shipped"
echo "self-contained libraries: $(wc -l < "${work}/shipped" | tr -d ' ')"

: > "${work}/problems"
checked=0
for f in "${prefix}"/bin/* "${prefix}"/lib/*.so* "${prefix}"/deps/*.so*; do
	[ -f "${f}" ] || continue
	# ldd exits 0 even with unresolved entries, so the greps below are the real gates.
	# stderr is dropped only because bin/ also holds non-ELF files that ldd rejects.
	ldd "${f}" > "${work}/ldd" 2>/dev/null || continue
	checked=$((checked + 1))

	grep 'not found' "${work}/ldd" \
		| sed "s|^[[:space:]]*|UNRESOLVED  ${f}: |" >> "${work}/problems" || true

	sed -n 's|^[[:space:]]*\([^[:space:]]*\.so[^[:space:]]*\) => \(/[^[:space:]]*\).*|\1 \2|p' \
		"${work}/ldd" > "${work}/links"
	while read -r soname path; do
		grep -Fxq "${soname}" "${work}/shipped" || continue
		case "${path}" in
			"${prefix}"/*) ;;
			*) echo "SHADOWED    ${f}: ${soname} => ${path}" >> "${work}/problems" ;;
		esac
	done < "${work}/links"
done

if [ "${checked}" = 0 ]; then
	echo "ERROR: no ELF objects found under ${prefix}; the image is not what we expect" >&2
	exit 1
fi

if [ -s "${work}/problems" ]; then
	echo 'ERROR: runtime link check failed.' >&2
	echo '  UNRESOLVED = the image does not contain a library a binary needs (it would exit 127).' >&2
	echo '  SHADOWED   = a bundled library lost resolution to a copy outside the install prefix,' >&2
	echo '               so the image would run against that instead of the version upstream pins.' >&2
	sort -u "${work}/problems" | sed 's/^/  /' >&2
	exit 1
fi

echo "runtime link check: ${checked} objects, all resolve, every bundled library wins resolution"
