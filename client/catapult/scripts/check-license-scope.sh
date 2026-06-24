#!/usr/bin/env bash
#
# check-license-scope.sh
#
# Verifies that the catapult source compiled into the self-contained image is
# LGPL-3.0 ONLY (plus the known Public-Domain ed25519-donna in external/donna) and
# carries NO Tech Bureau Commercial-licensed files. This is the single source of truth
# for the "licensing gate" in docs/PUBLISHING-COMPLIANCE.md (Section 1) and is run by
# .github/workflows/catapult-image.yml.
#
# `client/catapult/LICENSE.txt` dual-licenses each file (LGPL-3.0 unless a header or a
# directory LICENSE declares the Tech Bureau Commercial License), so an upstream sync
# *could* introduce commercial files later. This script is how that is detected.
#
# Exit status:
#   0 = scope is clean (safe to publish, pending the human sign-off)
#   1 = something outside LGPL-3.0 / known-PD scope was found (do NOT publish)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATAPULT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" # client/catapult
cd "${CATAPULT_DIR}"

fail=0

echo "== (1) directory-level LICENSE/COPYING declarations =="
# Only the two root files are expected; anything else may declare a separate license.
unexpected="$(find . -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname '*.license' \) \
  | grep -vE '^\./(LICENSE\.txt|COPYING\.LESSER)$' || true)"
if [ -n "${unexpected}" ]; then
  echo "  FAIL: unexpected license declaration(s):"
  printf '    %s\n' ${unexpected}
  fail=1
else
  echo "  OK: only root COPYING.LESSER + LICENSE.txt"
fi

echo "== (2) commercial / proprietary markers in source =="
# NB: 'All rights reserved' is part of the standard LGPL header, so it is NOT a marker.
markers="$(grep -rilE 'tech bureau commercial|commercial license|proprietary|confidential' \
  --include='*.h' --include='*.cpp' --include='*.hpp' --include='*.c' --include='*.inc' . || true)"
if [ -n "${markers}" ]; then
  echo "  FAIL: file(s) with commercial/proprietary markers:"
  printf '    %s\n' ${markers}
  fail=1
else
  echo "  OK: 0 files"
fi

echo "== (3) compiled source without the LGPL header (external/donna = Public Domain, allowed) =="
nonlgpl=""
for d in src plugins extensions tools sdk external; do
  [ -d "${d}" ] || continue
  while IFS= read -r f; do
    case "${f}" in ./external/donna/*) continue ;; esac
    if ! grep -qi 'GNU Lesser General Public License' "${f}"; then
      nonlgpl="${nonlgpl}${f}"$'\n'
    fi
  done < <(find "./${d}" -type f \( -name '*.h' -o -name '*.cpp' -o -name '*.hpp' -o -name '*.c' \))
done
if [ -n "${nonlgpl}" ]; then
  echo "  FAIL: non-LGPL source outside external/donna (needs license review):"
  printf '%s' "${nonlgpl}" | sed 's/^/    /'
  fail=1
else
  echo "  OK: every compiled source is LGPL-headed (only external/donna is Public Domain)"
fi

echo
if [ "${fail}" -ne 0 ]; then
  echo "RESULT: license-scope check FAILED."
  echo "Do NOT publish a catapult image from this revision until the findings are reviewed"
  echo "(see client/catapult/docs/PUBLISHING-COMPLIANCE.md)."
  exit 1
fi
echo "RESULT: license-scope check PASSED — LGPL-3.0 scope only, no commercial-licensed files."
