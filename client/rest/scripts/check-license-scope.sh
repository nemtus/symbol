#!/usr/bin/env bash
#
# check-license-scope.sh
#
# Verifies that the client/rest source shipped in the image is LGPL-3.0 ONLY (plus
# known generated / third-party files) and carries NO Tech Bureau Commercial-licensed
# files. This is the single source of truth for the "licensing gate" in
# docs/PUBLISHING-COMPLIANCE.md and is run by .github/workflows/rest-image.yml and
# inside client/rest/Dockerfile.nemtus.
#
# client/rest/LICENSE.txt dual-licenses each file (LGPL-3.0 unless a header or a
# directory LICENSE declares the Tech Bureau Commercial License), so an upstream sync
# *could* introduce commercial files later. This script is how that is detected.
#
# Allowlisted non-LGPL source (not commercial; reviewed):
#   - src/plugins/rosetta/openApi/**  generated Rosetta OpenAPI client (Coinbase, Apache-2.0)
#   - src/plugins/metadata/metal.js   rest's own code that ships without a header
#
# Exit status:
#   0 = scope is clean (safe to publish)
#   1 = something outside the LGPL-3.0 / allowlisted scope was found (do NOT publish)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" # client/rest
cd "${REST_DIR}"

fail=0

echo "== (1) directory-level LICENSE/COPYING declarations (node_modules/licenses excluded) =="
# Only the two root files are expected; anything else may declare a separate license.
# node_modules holds third-party (permissive) packages, and ./licenses is where the
# Dockerfile writes this gate's own LICENSE-SCOPE-REPORT.txt; both are excluded.
unexpected="$(find . \( -path ./node_modules -o -path ./licenses \) -prune -o -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname '*.license' \) -print \
  | grep -vE '^\./(LICENSE\.txt|COPYING\.LESSER)$' || true)"
if [ -n "${unexpected}" ]; then
  echo "  FAIL: unexpected license declaration(s):"
  printf '%s\n' "${unexpected}" | sed 's/^/    /'
  fail=1
else
  echo "  OK: only root COPYING.LESSER + LICENSE.txt"
fi

echo "== (2) commercial-license markers across the whole shipped tree =="
# The image ships the entire client/rest tree (COPY . .), so scan it all, not just src.
# A file placed under the Tech Bureau Commercial License names it (like the LGPL header
# names the LGPL), so the high-signal phrases below are scanned tree-wide -- EXCEPT the
# files that legitimately *describe* the dual license rather than being licensed under it.
# (node_modules holds third-party permissive packages; ./licenses is this gate's report.)
# 'All rights reserved' is part of the standard LGPL header, so it is NOT a marker; the
# generic 'proprietary'/'confidential' words appear in upstream docs (CODE_OF_CONDUCT etc.)
# so they are only applied to src/*.js where they are meaningful and noise-free.
meta_allow='^\./(LICENSE\.txt|COPYING\.LESSER|THIRD_PARTY_NOTICES\.md|Dockerfile\.nemtus|docs/PUBLISHING-COMPLIANCE\.md|scripts/check-license-scope\.sh)$'
tree_markers="$(grep -rilE 'tech bureau commercial|commercial license' . \
    --exclude-dir=node_modules --exclude-dir=licenses --exclude-dir=.git 2>/dev/null \
  | grep -vE "${meta_allow}" || true)"
src_markers="$(grep -rilE 'proprietary|confidential' --include='*.js' src 2>/dev/null || true)"
markers="$(printf '%s\n%s\n' "${tree_markers}" "${src_markers}" | grep -vE '^[[:space:]]*$' | sort -u || true)"
if [ -n "${markers}" ]; then
  echo "  FAIL: file(s) with commercial/proprietary markers:"
  printf '%s\n' "${markers}" | sed 's/^/    /'
  fail=1
else
  echo "  OK: 0 files"
fi

echo "== (3) src/*.js without the LGPL header (generated Rosetta client + metal.js allowed) =="
nonlgpl=""
while IFS= read -r f; do
  case "${f}" in
    ./src/plugins/rosetta/openApi/*) continue ;;
    ./src/plugins/metadata/metal.js) continue ;;
  esac
  if ! grep -qi 'GNU Lesser General Public License' "${f}"; then
    nonlgpl="${nonlgpl}${f}"$'\n'
  fi
done < <(find ./src -type f -name '*.js')
if [ -n "${nonlgpl}" ]; then
  echo "  FAIL: non-LGPL src .js outside the allowlist (needs license review):"
  printf '%s' "${nonlgpl}" | sed 's/^/    /'
  fail=1
else
  echo "  OK: every src .js is LGPL-headed (except the allowlisted generated/headerless files)"
fi

echo
if [ "${fail}" -ne 0 ]; then
  echo "RESULT: license-scope check FAILED."
  echo "Do NOT publish a symbol-rest image from this revision until the findings are reviewed"
  echo "(see client/rest/docs/PUBLISHING-COMPLIANCE.md)."
  exit 1
fi
echo "RESULT: license-scope check PASSED — LGPL-3.0 scope only, no commercial-licensed files."
