#!/usr/bin/env bash
#
# test-runtime-staging.sh — exercise stage-runtime-tree.sh and verify-runtime-links.sh
# without building catapult.
#
# WHY THIS EXISTS
# ---------------
# Four consecutive CI builds — about five and a half hours — were spent finding four
# separate bugs in those two steps, because the only way to reach them was to compile
# catapult first. Every one of the bugs was in shell that runs in well under a minute.
#
# Worse, the first three fixes were "verified" against test data invented to match the
# assumption being tested: a fake /opt/deps where every dependency had a .so, which is
# precisely what `google` does not. That is why the fixture here is REAL — fixtures/ holds
# the NEEDED graph those CI builds actually reported, 148 binaries and 639 edges,
# including the transitive mongo C++ -> C driver edges and the layouts that broke each
# attempt (OpenSSL flat in its prefix, googletest static with no .so, rocksdb's SONAME a
# symlink).
#
# The stubs below are the only fiction: `objdump` and `ldd` replay the recorded graph
# instead of reading ELF headers, so no compiled artifacts are needed. Everything else —
# the directory layouts, the SONAMEs, which dependency has which library — is observed.
#
# Usage: test-runtime-staging.sh
# Requires: a POSIX shell, awk, sed, find. No Docker, no compiler, no network.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${script_dir}/fixtures"
graph="${fixtures}/catapult-needed-graph.tsv"

[ -f "${graph}" ] || { echo "missing fixture: ${graph}" >&2; exit 1; }

pass=0
fail=0

note() { printf '  %s\n' "$*"; }
ok()   { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }

# Build a sandbox that mirrors the real builder stage: the recorded artifact list in
# _build/bin, and /opt/deps laid out the way upstream's installDepsLocal.py leaves it.
make_sandbox() {
	local root="$1"
	mkdir -p "${root}"/{stub,src/_build/bin,src/resources,opt/catapult}
	mkdir -p "${root}"/opt/deps/{boost,facebook,google,mongodb,zeromq}/lib "${root}"/opt/deps/openssl

	# googletest / benchmark: static and test-only. No .so at all — attempt 2 failed here.
	touch "${root}/opt/deps/google/lib/libgtest.a" "${root}/opt/deps/google/lib/GTestConfig.cmake"
	# OpenSSL: --libdir equals the prefix, so these are FLAT — attempt 1 failed here.
	touch "${root}/opt/deps/openssl/libcrypto.so.4" "${root}/opt/deps/openssl/libssl.so.4"
	# boost: b2 --prefix, libraries under lib/.
	local b
	for b in filesystem log program_options thread; do
		touch "${root}/opt/deps/boost/lib/libboost_${b}.so.1.91.0"
	done
	# rocksdb: the SONAME is a symlink to the real file.
	touch "${root}/opt/deps/facebook/lib/librocksdb.so.11.8.1"
	ln -sf librocksdb.so.11.8.1 "${root}/opt/deps/facebook/lib/librocksdb.so.11"
	# mongo: C++ drivers AND the C drivers they need — attempt 4 failed on the latter.
	touch "${root}/opt/deps/mongodb/lib/libbsoncxx1.so.1" "${root}/opt/deps/mongodb/lib/libmongocxx1.so.1"
	touch "${root}/opt/deps/mongodb/lib/libbson2.so.2" "${root}/opt/deps/mongodb/lib/libmongoc2.so.2"
	touch "${root}/opt/deps/zeromq/lib/libzmq.so.5"

	# The real artifact list. Libraries that live in /opt/deps are excluded: in a real
	# build they are dependencies, not build outputs.
	cut -f1 "${graph}" | sort -u \
		| grep -vE '^lib(bsoncxx1|mongocxx1)\.so' \
		| while read -r a; do touch "${root}/src/_build/bin/${a}"; done

	touch "${root}/src/resources/config.properties" \
		"${root}/src/COPYING.LESSER" "${root}/src/LICENSE.txt" "${root}/src/THIRD_PARTY_NOTICES.md"

	# objdump stub: replay the recorded NEEDED edges for whatever file it is handed.
	cat > "${root}/stub/objdump" <<EOS
#!/bin/sh
for a in "\$@"; do last="\$a"; done
awk -F'\t' -v b="\$(basename "\$last")" '\$1==b { print "  NEEDED               "\$2 }' "${graph}"
EOS
	chmod +x "${root}/stub/objdump"
}

# ldd stub: resolve every recorded edge the way the runtime image would, i.e. out of the
# install prefix. Used to check the link check's happy path.
make_ldd_stub() {
	local root="$1" prefix="$2"
	cat > "${root}/stub/ldd" <<EOS
#!/bin/sh
for a in "\$@"; do last="\$a"; done
awk -F'\t' -v b="\$(basename "\$last")" -v P="${prefix}" '
  \$1==b {
    s=\$2
    if (s ~ /^libcatapult\.|^libextension\./) print "\t"s" => "P"/bin/"s" (0x1)"
    else print "\t"s" => "P"/deps/"s" (0x1)"
  }' "${graph}"
printf '\tlibstdc++.so.6 => /usr/lib/libstdc++.so.6 (0x2)\n'
EOS
	chmod +x "${root}/stub/ldd"
}

stage() {
	local root="$1"; shift
	( cd "${root}/src" && PATH="${root}/stub:${PATH}" sh "${script_dir}/stage-runtime-tree.sh" \
		--deps-dir "${root}/opt/deps" --dest "${root}/opt/catapult" "$@" )
}

# ---------------------------------------------------------------- staging, happy path
t="$(mktemp -d)"; make_sandbox "${t}"
if out="$(stage "${t}" 2>&1)"; then
	bundled="$(printf '%s\n' "${out}" | sed -n 's/^bundled: //p' | sort)"
	expected="libboost_filesystem.so.1.91.0
libboost_log.so.1.91.0
libboost_program_options.so.1.91.0
libboost_thread.so.1.91.0
libbson2.so.2
libbsoncxx1.so.1
libcrypto.so.4
libmongoc2.so.2
libmongocxx1.so.1
librocksdb.so.11
libssl.so.4
libzmq.so.5"
	if [ "${bundled}" = "${expected}" ]; then
		ok "staging bundles exactly the 12 libraries the recorded graph requires"
	else
		bad "staging bundled an unexpected set"
		note "--- got ---"; printf '%s\n' "${bundled}" | sed 's/^/    /'
		note "--- want ---"; printf '%s\n' "${expected}" | sed 's/^/    /'
	fi
else
	bad "staging failed on the happy path"; printf '%s\n' "${out}" | sed 's/^/    /'
fi

# Transitive closure is the point of attempt 4's fix: these two are named by NOTHING in
# bin/, only by the mongo C++ drivers that staging itself copies in.
for lib in libbson2.so.2 libmongoc2.so.2; do
	if [ -e "${t}/opt/catapult/deps/${lib}" ]; then
		ok "transitive dependency ${lib} is bundled"
	else
		bad "transitive dependency ${lib} is MISSING"
	fi
done

# googletest is static and test-only; requiring a .so from it broke attempt 2.
if [ -z "$(ls -A "${t}/opt/catapult/deps" | grep -i gtest || true)" ]; then
	ok "static test-only dependency (googletest) neither bundled nor fatal"
else
	bad "googletest should not be bundled"
fi

# ------------------------------------------------------------------------ idempotency
first="$(ls -1 "${t}/opt/catapult/deps" | sort)"
if out="$(stage "${t}" 2>&1)"; then
	if [ "$(ls -1 "${t}/opt/catapult/deps" | sort)" = "${first}" ]; then
		ok "re-running staging is idempotent"
	else
		bad "re-running staging changed the bundle"
	fi
else
	bad "re-running staging failed"; printf '%s\n' "${out}" | sed 's/^/    /'
fi

# --------------------------------------------------------------- link check, happy path
make_ldd_stub "${t}" "${t}/opt/catapult"
if out="$(PATH="${t}/stub:${PATH}" sh "${script_dir}/verify-runtime-links.sh" --prefix "${t}/opt/catapult" 2>&1)"; then
	ok "link check passes over the full recorded graph"
else
	bad "link check failed on the happy path"; printf '%s\n' "${out}" | sed 's/^/    /'
fi

# ------------------------------------------------- staging: a required SONAME is absent
t2="$(mktemp -d)"; make_sandbox "${t2}"
rm -f "${t2}/opt/deps/openssl/libcrypto.so.4"
if out="$(stage "${t2}" 2>&1)"; then
	bad "staging should fail when a required SONAME is absent"
else
	if printf '%s\n' "${out}" | grep -q 'libcrypto.so.4'; then
		ok "a missing direct dependency fails and is named"
	else
		bad "staging failed but did not name libcrypto.so.4"; printf '%s\n' "${out}" | sed 's/^/    /'
	fi
fi

# ------------------------------------- staging: a TRANSITIVE SONAME is absent (attempt 4)
t3="$(mktemp -d)"; make_sandbox "${t3}"
rm -f "${t3}/opt/deps/mongodb/lib/libbson2.so.2"
if out="$(stage "${t3}" 2>&1)"; then
	bad "staging should fail when a transitive SONAME is absent"
else
	if printf '%s\n' "${out}" | grep -q 'libbson2.so.2'; then
		ok "a missing transitive dependency fails and is named"
	else
		bad "staging failed but did not name libbson2.so.2"; printf '%s\n' "${out}" | sed 's/^/    /'
	fi
fi

# ------------------------------------------- staging: objdump yields nothing (attempt 3)
t4="$(mktemp -d)"; make_sandbox "${t4}"
printf '#!/bin/sh\nexit 0\n' > "${t4}/stub/objdump"; chmod +x "${t4}/stub/objdump"
if out="$(stage "${t4}" 2>&1)"; then
	# No NEEDED anywhere means nothing to bundle; that is only acceptable if it ALSO
	# means nothing was required, which the recorded graph says is false. The scanned
	# guard is what must catch a silently empty read.
	if [ -z "$(ls -A "${t4}/opt/catapult/deps")" ]; then
		bad "objdump returning nothing bundled nothing and still succeeded"
	else
		ok "objdump returning nothing did not fabricate a bundle"
	fi
else
	ok "objdump returning nothing is treated as a failure"
fi

# ------------------------------------------- link check: UNRESOLVED must be caught
t5="$(mktemp -d)"; make_sandbox "${t5}"
stage "${t5}" >/dev/null 2>&1
cat > "${t5}/stub/ldd" <<'EOS'
#!/bin/sh
printf '\tlibcrypto.so.4 => not found\n'
EOS
chmod +x "${t5}/stub/ldd"
if out="$(PATH="${t5}/stub:${PATH}" sh "${script_dir}/verify-runtime-links.sh" --prefix "${t5}/opt/catapult" 2>&1)"; then
	bad "link check should fail on an unresolved library"
else
	printf '%s\n' "${out}" | grep -q 'UNRESOLVED' \
		&& ok "link check reports UNRESOLVED" \
		|| { bad "link check failed without reporting UNRESOLVED"; printf '%s\n' "${out}" | sed 's/^/    /'; }
fi

# ------------------------------- link check: SHADOWED must be caught (the silent case)
cat > "${t5}/stub/ldd" <<'EOS'
#!/bin/sh
printf '\tlibcrypto.so.4 => /usr/lib/x86_64-linux-gnu/libcrypto.so.4 (0x1)\n'
EOS
chmod +x "${t5}/stub/ldd"
if out="$(PATH="${t5}/stub:${PATH}" sh "${script_dir}/verify-runtime-links.sh" --prefix "${t5}/opt/catapult" 2>&1)"; then
	bad "link check should fail when a bundled library is shadowed"
else
	printf '%s\n' "${out}" | grep -q 'SHADOWED' \
		&& ok "link check reports SHADOWED" \
		|| { bad "link check failed without reporting SHADOWED"; printf '%s\n' "${out}" | sed 's/^/    /'; }
fi

rm -rf "${t}" "${t2}" "${t3}" "${t4}" "${t5}"

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = 0 ]
