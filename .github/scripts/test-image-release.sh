#!/usr/bin/env bash
#
# test-image-release.sh — offline tests for image-release.sh.
#
# A stub `gh` on PATH stands in for the GitHub API: it serves a Release body from a
# state directory (or reports "not found") and records create/edit calls, so the
# create / append / idempotency paths can be checked without network or credentials.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/image-release.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin"
cat >"${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stand-in. State: $STATE/body (existing Release body; absent = no Release).
set -euo pipefail
echo "gh $*" >>"${STATE}/calls"
notes_from_args() {
	while [ $# -gt 0 ]; do
		if [ "$1" = '--notes-file' ]; then cat "$2"; return; fi
		shift
	done
}
case "$1 $2" in
	'release view')
		[ -f "${STATE}/body" ] || { echo 'release not found' >&2; exit 1; }
		cat "${STATE}/body"
		;;
	'release create' | 'release edit')
		notes_from_args "$@" >"${STATE}/body"
		;;
	*)
		echo "unexpected gh call: $*" >&2
		exit 1
		;;
esac
STUB
chmod +x "${work}/bin/gh"

fail=0
check() { # check <description> <command...>
	local desc="$1"
	shift
	if "$@"; then
		echo "ok   - ${desc}"
	else
		echo "FAIL - ${desc}"
		fail=1
	fi
}

run() { # run <state-dir> [VAR=value...] — runs image-release.sh against the stub
	local state="$1"
	shift
	env PATH="${work}/bin:${PATH}" STATE="${state}" GH_TOKEN=dummy \
		GITHUB_REPOSITORY=nemtus/symbol COMPONENT=catapult \
		RELEASE_TAG=catapult-image-v1.0.3.10 DATED_TAG=v1.0.3.10-20261114 \
		DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa VCS_REF=ad84053 BUILD_KIND=release RUN_URL=https://run/1 \
		CHANGELOG_FILE="${work}/CHANGELOG.md" "$@" bash "${script}"
}

cat >"${work}/CHANGELOG.md" <<'EOF'
# Changelog

## [1.0.3.10] - 11-Nov-2026

### Fixed
- (BREAKING FORK) the fix

## [1.0.3.9] - 21-Sep-2025

### Fixed
- older fix

[1.0.3.10]: https://example/compare
EOF

# 1. First publish creates the Release with one Builds row and the changelog section.
s="${work}/s1"
mkdir -p "${s}"
run "${s}" >/dev/null
check 'first publish creates the Release' grep -q '^gh release create catapult-image-v1.0.3.10 ' "${s}/calls"
check 'create keeps the SDK as Latest' grep -q -- '--latest=false' "${s}/calls"
check 'create records the dated tag row' grep -qF '| `v1.0.3.10-20261114` | `sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` | `ad84053` | release |' "${s}/body"
check 'changelog section of this version only' grep -qF '(BREAKING FORK) the fix' "${s}/body"
check 'older changelog sections excluded' bash -c "! grep -qF 'older fix' '${s}/body'"
check 'changelog headings demoted' grep -qx '#### Fixed' "${s}/body"

# 2. Re-running the same publish changes nothing.
run "${s}" >/dev/null
check 're-run does not create or edit again' test "$(grep -c -E '^gh release (create|edit)' "${s}/calls")" = 1

# 3. A security rebuild appends its row above the marker, keeping the first one.
run "${s}" BUILD_KIND=rebuild DATED_TAG=v1.0.3.10-20261201 DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null
check 'rebuild edits the Release' grep -q '^gh release edit catapult-image-v1.0.3.10 ' "${s}/calls"
check 'rebuild keeps the first row' grep -qF '`v1.0.3.10-20261114`' "${s}/body"
check 'rebuild adds its row' grep -qF '| `v1.0.3.10-20261201` | `sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` | `ad84053` | security rebuild |' "${s}/body"
check 'rows stay in order above the marker' bash -c "
	grep -n -e '20261114\` |' -e '20261201\` |' -e 'nemtus:image-builds' '${s}/body' | cut -d: -f1 | tr '\n' ' ' |
	awk '{ exit !(\$1 < \$2 && \$2 < \$3) }'"
check 'exactly one marker' test "$(grep -c 'nemtus:image-builds' "${s}/body")" = 1

# 4. Re-running the rebuild is a no-op.
before="$(cat "${s}/body")"
run "${s}" BUILD_KIND=rebuild DATED_TAG=v1.0.3.10-20261201 DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null
check 'rebuild re-run leaves the body unchanged' test "${before}" = "$(cat "${s}/body")"

# 5. A hand-written Release (no marker) gets a Builds section appended on rebuild,
#    and is left untouched by a first-publish run.
s="${work}/s5"
mkdir -p "${s}"
printf 'Hand-written notes.\n' >"${s}/body"
run "${s}" >/dev/null
check 'first publish leaves a hand-written Release alone' test "$(cat "${s}/body")" = 'Hand-written notes.'
run "${s}" BUILD_KIND=rebuild DATED_TAG=v1.0.3.10-20261201 >/dev/null
check 'hand-written body is preserved' grep -qx 'Hand-written notes.' "${s}/body"
check 'Builds section appended' grep -qx '### Builds' "${s}/body"
check 'rebuild row appended' grep -qF '`v1.0.3.10-20261201`' "${s}/body"

# 6. rest uses its own image, upstream tag and `[v<version>]` changelog headings.
s="${work}/s6"
mkdir -p "${s}"
printf '## [v2.5.2] - 11-Nov-2026\n\n### Added\n- trustProxy\n\n## [v2.5.1] - x\n- old\n' >"${work}/CHANGELOG.rest.md"
run "${s}" COMPONENT=rest RELEASE_TAG=rest-image-v2.5.2 DATED_TAG=v2.5.2-20261114 \
	CHANGELOG_FILE="${work}/CHANGELOG.rest.md" >/dev/null
check 'rest Release title' grep -qF -- "--title ghcr.io/nemtus/symbol-rest v2.5.2" "${s}/calls"
check 'rest upstream tag' grep -qF '(upstream tag `rest/v2.5.2`)' "${s}/body"
check 'rest changelog section' grep -qF -- '- trustProxy' "${s}/body"
check 'rest older section excluded' bash -c "! grep -qF -- '- old' '${s}/body'"

# 7. Malformed inputs are rejected before any gh call.
s="${work}/s7"
mkdir -p "${s}"
check 'rejects a non-release tag' bash -c "! { $(declare -f run); work='${work}'; script='${script}'; run '${s}' RELEASE_TAG=dev; } 2>/dev/null"
check 'rejects a dated tag of another version' bash -c "! { $(declare -f run); work='${work}'; script='${script}'; run '${s}' DATED_TAG=v1.0.3.9-20261114; } 2>/dev/null"
check 'rejects an unrecorded digest' bash -c "! { $(declare -f run); work='${work}'; script='${script}'; run '${s}' DIGEST=unknown; } 2>/dev/null"
check 'rejects an unknown component' bash -c "! { $(declare -f run); work='${work}'; script='${script}'; run '${s}' COMPONENT=broker; } 2>/dev/null"
check 'no gh call on rejected input' test ! -e "${s}/calls"

exit "${fail}"
