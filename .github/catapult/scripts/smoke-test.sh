#!/bin/sh
#
# smoke-test.sh — run the shipped binaries before the image can be published.
#
# Run inside the RUNTIME stage, after verify-runtime-links.sh. The two checks are not
# redundant and neither subsumes the other:
#
#   verify-runtime-links.sh  reads ELF NEEDED entries and proves every one resolves to a
#                            library the image ships. Static analysis: nothing executes.
#
#   this script              executes a binary. That is the only way to catch a dependency
#                            that is loaded by dlopen, because dlopen'd objects appear in
#                            no NEEDED entry and therefore in no SONAME-based scan.
#
# The second case is not hypothetical. OpenSSL 4 delegates algorithms to provider modules
# in ossl-modules, loaded by dlopen. An image missing them passes the link check cleanly
# and then dies with SIGSEGV the first time a binary asks for a hash. That is exactly the
# failure this repo hit while the Dockerfile was hand-written, and a smoke test is what
# found it.
#
# Why this lives in the Dockerfile rather than in a workflow step: the workflow's
# "Smoke test (toolchain runs)" step is gated `if: steps.meta.outputs.push != 'true'`, so
# it ran on verify builds and never on the builds that actually ship. A security rebuild is
# precisely a push build whose binaries differ from anything previously tested — refreshed
# base layers mean a new compile — so the one check that catches dlopen breakage was absent
# from the only runs where it mattered. As a RUN it gates the publish: a binary that cannot
# run fails the build, and nothing is pushed.
set -eu

fail() {
	echo "SMOKE FAIL: $*" >&2
	exit 1
}

# addressgen exercises OpenSSL end to end — key generation and hashing — which is what
# makes it the right binary to run rather than something that only prints a version string.
addr="$(catapult.tools.addressgen --count 1 2>&1)" || fail "addressgen exited non-zero: ${addr}"
printf '%s\n' "${addr}"

# Guard against a binary that exits 0 having produced nothing. Symbol addresses are
# base32, 39 characters.
printf '%s' "${addr}" | grep -qE '[A-Z2-7]{39}' \
	|| fail "addressgen exited 0 but produced no address"

# The license files have to ship with the binaries they cover; see
# client/catapult/docs/PUBLISHING-COMPLIANCE.md.
[ -d /opt/catapult/licenses ] || fail "/opt/catapult/licenses is missing"
licenses="$(find /opt/catapult/licenses -type f | wc -l | tr -d ' ')"
[ "${licenses}" -gt 0 ] || fail "/opt/catapult/licenses contains no files"

echo "smoke test: addressgen produced an address, ${licenses} license files present"
