#!/usr/bin/env bash
#
# test-runtime-links.sh — exercise verify-runtime-links.sh without building an image.
#
# WHY THIS EXISTS
# ---------------
# verify-runtime-links.sh is the only check nemtus adds on top of upstream's build, and
# it runs in the runtime stage — i.e. at the end of a ~90 minute build. Six consecutive
# builds were spent discovering bugs reachable only there. This harness reaches the same
# code in seconds.
#
# Its earlier form also tested a nemtus-written dependency-staging step. That step is
# gone: upstream's runDockerBuildInnerBuild.py already stages dependencies, and it knows
# things a SONAME scan cannot — notably OpenSSL 4's `ossl-modules`, which is loaded by
# dlopen and therefore appears in no ELF NEEDED entry. Five of those six builds were spent
# reimplementing, badly, something upstream had already solved.
#
# What remains worth testing is the verification itself, because upstream does not do it:
# upstream builds and runs its images in one pipeline, whereas nemtus republishes an image
# for others to pull, so "does this image actually load" is our question to answer.
#
# The fixture is the NEEDED graph the failing builds recorded — 148 objects, 640 edges —
# so the expectations are observed rather than invented. Only `ldd` is stubbed, to replay
# the graph instead of reading ELF headers.
#
# Usage: test-runtime-links.sh
# Requires: a POSIX shell, awk, sed. No Docker, no compiler, no network.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
graph="${script_dir}/fixtures/catapult-needed-graph.tsv"
[ -f "${graph}" ] || { echo "missing fixture: ${graph}" >&2; exit 1; }

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }

# A tree shaped like the one upstream's build produces: executables and catapult's own
# plugin shared objects in lib/, third-party dependencies in deps/, OpenSSL's provider
# modules in deps/ossl-modules/.
make_image() {
	local root="$1"
	mkdir -p "${root}"/stub "${root}"/opt/catapult/{bin,lib,deps/ossl-modules}

	# Objects that are build outputs, not dependencies.
	cut -f1 "${graph}" | sort -u | while read -r a; do
		case "${a}" in
			libcatapult.*|libextension.*) touch "${root}/opt/catapult/lib/${a}" ;;
			lib*) : ;;   # dependency libraries are created below
			*) touch "${root}/opt/catapult/bin/${a}" ;;
		esac
	done

	# Third-party dependencies, as upstream's copy_dependencies stages them.
	local d
	for d in libboost_filesystem.so.1.91.0 libboost_log.so.1.91.0 \
	         libboost_program_options.so.1.91.0 libboost_thread.so.1.91.0 \
	         libbson2.so.2 libmongoc2.so.2 libbsoncxx1.so.1 libmongocxx1.so.1 \
	         libzmq.so.5 librocksdb.so.11 libcrypto.so.4 libssl.so.4; do
		touch "${root}/opt/catapult/deps/${d}"
	done
	touch "${root}/opt/catapult/deps/ossl-modules/legacy.so"
}

# Resolve every recorded edge the way the runtime image would: build outputs out of lib/,
# dependencies out of deps/, and the distro's own libraries from /usr/lib.
make_ldd() {
	local root="$1" prefix="$2"
	cat > "${root}/stub/ldd" <<EOS
#!/bin/sh
for a in "\$@"; do last="\$a"; done
awk -F'\t' -v b="\$(basename "\$last")" -v P="${prefix}" '
  \$1==b {
    s=\$2
    if (s ~ /^libcatapult\.|^libextension\./) print "\t"s" => "P"/lib/"s" (0x1)"
    else if (s ~ /^lib(c|m|dl|rt|pthread|resolv|stdc\+\+|gcc_s|atomic)\./) print "\t"s" => /usr/lib/"s" (0x2)"
    else print "\t"s" => "P"/deps/"s" (0x1)"
  }' "${graph}"
EOS
	chmod +x "${root}/stub/ldd"
}

check() {
	local root="$1"
	( PATH="${root}/stub:${PATH}" sh "${script_dir}/verify-runtime-links.sh" \
		--prefix "${root}/opt/catapult" )
}

# ------------------------------------------------------------------ happy path
t="$(mktemp -d)"; make_image "${t}"; make_ldd "${t}" "${t}/opt/catapult"
if out="$(check "${t}" 2>&1)"; then
	ok "a correctly staged image passes"
else
	bad "a correctly staged image was rejected"; printf '%s\n' "${out}" | sed 's/^/    /'
fi

# Distro libraries must keep resolving to the distro: they are not shipped, so they must
# not be reported as shadowed.
if printf '%s\n' "${out:-}" | grep -q 'SHADOWED'; then
	bad "distro libraries were misreported as shadowed"
else
	ok "libraries the image does not ship are not treated as shadowed"
fi

# ------------------------------------------------------------------- UNRESOLVED
t2="$(mktemp -d)"; make_image "${t2}"
cat > "${t2}/stub/ldd" <<'EOS'
#!/bin/sh
printf '\tlibcrypto.so.4 => not found\n'
EOS
chmod +x "${t2}/stub/ldd"
if out="$(check "${t2}" 2>&1)"; then
	bad "an unresolved library should fail the check"
else
	printf '%s\n' "${out}" | grep -q 'UNRESOLVED' \
		&& ok "an unresolved library is reported as UNRESOLVED" \
		|| { bad "failed without reporting UNRESOLVED"; printf '%s\n' "${out}" | sed 's/^/    /'; }
fi

# --------------------------------------------------------------------- SHADOWED
# The silent case: ldd is perfectly happy, but a library the image ships lost resolution
# to a copy outside the prefix, so the binary runs against the distro's build instead of
# the version upstream pins. For months the image bundled no OpenSSL at all and looked
# exactly like this.
t3="$(mktemp -d)"; make_image "${t3}"
cat > "${t3}/stub/ldd" <<'EOS'
#!/bin/sh
printf '\tlibcrypto.so.4 => /usr/lib/x86_64-linux-gnu/libcrypto.so.4 (0x1)\n'
EOS
chmod +x "${t3}/stub/ldd"
if out="$(check "${t3}" 2>&1)"; then
	bad "a shadowed bundled library should fail the check"
else
	printf '%s\n' "${out}" | grep -q 'SHADOWED' \
		&& ok "a shadowed bundled library is reported as SHADOWED" \
		|| { bad "failed without reporting SHADOWED"; printf '%s\n' "${out}" | sed 's/^/    /'; }
fi

# ------------------------------------------------------- nothing to check is a failure
# An empty or wrongly-shaped prefix must not pass silently: "no problems found" over zero
# objects is indistinguishable from success, and would wave through a broken image.
t4="$(mktemp -d)"; mkdir -p "${t4}/opt/catapult" "${t4}/stub"
if out="$(check "${t4}" 2>&1)"; then
	bad "an empty prefix should fail the check"
else
	ok "an image with no ELF objects is treated as a failure"
fi

rm -rf "${t}" "${t2}" "${t3}" "${t4}"
printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = 0 ]
