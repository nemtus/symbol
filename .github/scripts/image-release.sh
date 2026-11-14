#!/usr/bin/env bash
#
# image-release.sh
#
# Creates (or updates) the GitHub Release for a published nemtus container image:
#   ghcr.io/<owner>/catapult-server  <- catapult-image.yml, release tag catapult-image-v<X>
#   ghcr.io/<owner>/symbol-rest      <- rest-image.yml,     release tag rest-image-v<Y>
#
# Called by the `release` job of those workflows AFTER the image has been pushed. That
# job is the only place `contents: write` is granted and it runs nothing but this script
# and the gh CLI — no build, no third-party code — mirroring the tag job of publish.yml.
#
# Every publish of a release produces one IMMUTABLE dated image tag (v<X>-<YYYYMMDD>),
# and the Release keeps one row per such build in its "Builds" table:
#   - first publish (push of the git tag)  -> create the Release with the first row;
#   - security rebuild (dispatch with release_tag) -> append a row to the existing Release
#     (or create it, for a release that predates this automation).
# Idempotent: a row whose dated tag is already in the Release is never added twice, and
# re-running a first publish never rewrites an existing Release.
#
# Inputs (environment):
#   COMPONENT     catapult | rest
#   RELEASE_TAG   git tag of the release, e.g. catapult-image-v1.0.3.10
#   DATED_TAG     immutable image tag published by this run, e.g. v1.0.3.10-20261114
#   DIGEST        image manifest digest (sha256:...)
#   VCS_REF       short commit the image was built from
#   BUILD_KIND    release | rebuild
#   RUN_URL       URL of the workflow run (optional)
#   GITHUB_REPOSITORY, GH_TOKEN   as provided by Actions
#   CHANGELOG_FILE  (tests) read the changelog from this file instead of the GitHub API
#
# Usage:
#   image-release.sh              create / update the Release
#   image-release.sh --print      print the notes a NEW Release would get, change nothing
set -euo pipefail

mode="${1:-apply}"
case "${mode}" in
	apply | --print) ;;
	*)
		echo "usage: $0 [--print]" >&2
		exit 2
		;;
esac

: "${COMPONENT:?COMPONENT must be catapult or rest}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${DATED_TAG:?DATED_TAG is required}"
: "${DIGEST:?DIGEST is required}"
: "${VCS_REF:?VCS_REF is required}"
: "${BUILD_KIND:?BUILD_KIND must be release or rebuild}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
RUN_URL="${RUN_URL:-}"

owner="${GITHUB_REPOSITORY%%/*}"
case "${COMPONENT}" in
	catapult)
		tag_prefix='catapult-image-'
		image="ghcr.io/${owner}/catapult-server"
		upstream_prefix='client/catapult/v'
		changelog_path='client/catapult/CHANGELOG.md'
		notices_path='client/catapult/THIRD_PARTY_NOTICES.md'
		license_report='/opt/catapult/licenses/LICENSE-SCOPE-REPORT.txt'
		subject='Self-contained container image of Symbol'"'"'s **catapult-server**'
		upstream_name='catapult'
		about='- Built from canonical upstream sources — no `symbolplatform/*` prebuilt base image and no
  `conan.symbol.dev` Conan remote. Ships `catapult.server`, `catapult.broker`,
  `catapult.recovery` and `catapult.tools.*`.'
		trademark=' "Symbol" / "NEM" are trademarks of their respective owners.'
		;;
	rest)
		tag_prefix='rest-image-'
		image="ghcr.io/${owner}/symbol-rest"
		upstream_prefix='rest/v'
		changelog_path='client/rest/CHANGELOG.md'
		notices_path='client/rest/THIRD_PARTY_NOTICES.md'
		license_report='/app/licenses/LICENSE-SCOPE-REPORT.txt'
		subject='Container image of Symbol'"'"'s **REST gateway** (`symbol-api-rest`)'
		upstream_name='rest'
		about='- Mirrors the upstream `client/rest` build (Node.js on Ubuntu, production dependencies
  only). For compatibility with catapult-server, see `client/rest/COMPATIBILITY.md`.'
		trademark=''
		;;
	*)
		echo "::error::unknown COMPONENT '${COMPONENT}' (expected catapult or rest)" >&2
		exit 2
		;;
esac

# catapult-image-v1.0.3.10 -> v1.0.3.10 -> 1.0.3.10
version="${RELEASE_TAG#"${tag_prefix}"}"
if [ "${version}" = "${RELEASE_TAG}" ] || ! printf '%s' "${version}" | grep -qE '^v[0-9]+(\.[0-9]+)*$'; then
	echo "::error::RELEASE_TAG '${RELEASE_TAG}' is not a ${tag_prefix}v<version> release tag" >&2
	exit 2
fi
bare_version="${version#v}"
if ! printf '%s' "${DATED_TAG}" | grep -qE "^${version//./\\.}-[0-9]{8}\$"; then
	echo "::error::DATED_TAG '${DATED_TAG}' is not ${version}-<YYYYMMDD>" >&2
	exit 2
fi
if ! printf '%s' "${DIGEST}" | grep -qE '^sha256:[0-9a-f]{64}$'; then
	echo "::error::DIGEST '${DIGEST}' is not a sha256 image digest (the publish could not record it)" >&2
	exit 2
fi
case "${BUILD_KIND}" in
	release) kind_label='release' ;;
	rebuild) kind_label='security rebuild' ;;
	*)
		echo "::error::BUILD_KIND must be release or rebuild, got '${BUILD_KIND}'" >&2
		exit 2
		;;
esac

upstream_tag="${upstream_prefix}${bare_version}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
changelog_url="${server_url}/${GITHUB_REPOSITORY}/blob/${RELEASE_TAG}/${changelog_path}"
marker='<!-- nemtus:image-builds -->'
builds_header='| Dated tag (immutable) | Digest | Source | Kind | Run |
| --- | --- | --- | --- | --- |'

run_cell='—'
[ -n "${RUN_URL}" ] && run_cell="[run](${RUN_URL})"
row="| \`${DATED_TAG}\` | \`${DIGEST}\` | \`${VCS_REF}\` | ${kind_label} | ${run_cell} |"

# The section of the released CHANGELOG for this version: from its `## [<version>]`
# heading (catapult writes `[1.0.3.10]`, rest writes `[v2.5.2]`) up to the next `## `
# heading or the trailing link-reference definitions. Sub-headings are demoted one level
# so they nest under this Release's own "Upstream changes" heading. Empty if not found.
changelog_section() {
	local text
	if [ -n "${CHANGELOG_FILE:-}" ]; then
		text="$(cat "${CHANGELOG_FILE}")"
	else
		text="$(gh api -H 'Accept: application/vnd.github.raw' \
			"repos/${GITHUB_REPOSITORY}/contents/${changelog_path}?ref=${RELEASE_TAG}" 2>/dev/null)" || return 0
	fi
	printf '%s\n' "${text}" | awk -v v="${bare_version}" '
		BEGIN { found = 0 }
		/^## / {
			if (found) exit
			h = $0
			sub(/^## \[v?/, "", h)
			sub(/\].*$/, "", h)
			if (h == v) { found = 1; next }
		}
		found && /^\[[^]]+\]: / { exit }
		found { sub(/^### /, "#### "); print }
	' | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

new_release_notes() {
	local section
	section="$(changelog_section)"
	cat <<EOF
${subject}, published by the ${owner} mirror, tracking upstream \`symbol/symbol\` ${upstream_name}
**${version}** (upstream tag \`${upstream_tag}\`).

\`\`\`
docker pull ${image}:${DATED_TAG}
\`\`\`

Pin the **newest dated tag** in the Builds table below — dated tags are immutable.
\`${version}\` and \`latest\` move to every newer build (security rebuilds refresh the base
layers of the same upstream source); \`sha-<commit>\` names the source commit.

### Builds

${builds_header}
${row}
${marker}

### Upstream changes in ${version}

EOF
	if [ -n "${section}" ]; then
		printf '%s\n\n' "${section}"
	fi
	cat <<EOF
See the upstream [\`${changelog_path}\`](${changelog_url}) for details.

### About
${about}
- **SBOM + SLSA provenance** attestations are attached, and an automated LGPL license-scope
  gate report is bundled in the image.

### License & provenance
LGPL-3.0-or-later. The complete corresponding source is this repository at the commit in
the image's \`org.opencontainers.image.revision\` label; third-party notices are in
\`${notices_path}\`. License-scope report in the image: \`${license_report}\`.

> Independent build by the ${owner} mirror; not affiliated with or endorsed by the upstream
> project owners.${trademark}
EOF
}

# Adds this run's row to an existing Release body: right above the marker when the body
# was written by this script, otherwise as a new Builds section at the end (Releases
# created by hand before this automation existed).
append_row() {
	local body="$1"
	if printf '%s\n' "${body}" | grep -qF "${marker}"; then
		printf '%s\n' "${body}" | awk -v row="${row}" -v m="${marker}" '$0 == m { print row } { print }'
	else
		printf '%s\n\n### Builds\n\n%s\n%s\n%s\n' "${body}" "${builds_header}" "${row}" "${marker}"
	fi
}

if [ "${mode}" = '--print' ]; then
	new_release_notes
	exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
notes_file="$(mktemp)"
trap 'rm -f "${notes_file}"' EXIT

if body="$(gh release view "${RELEASE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body -q .body 2>/dev/null)"; then
	if printf '%s\n' "${body}" | grep -qF "\`${DATED_TAG}\`"; then
		echo "Release ${RELEASE_TAG} already records ${DATED_TAG}; nothing to do."
		exit 0
	fi
	if [ "${BUILD_KIND}" = 'release' ]; then
		# A first publish never rewrites an existing Release (e.g. one written by hand);
		# only rebuilds append to it.
		echo "Release ${RELEASE_TAG} already exists; leaving it unchanged."
		exit 0
	fi
	append_row "${body}" >"${notes_file}"
	gh release edit "${RELEASE_TAG}" --repo "${GITHUB_REPOSITORY}" --notes-file "${notes_file}"
	echo "Appended ${DATED_TAG} to Release ${RELEASE_TAG}."
else
	new_release_notes >"${notes_file}"
	# --latest=false: the repository's "Latest" badge belongs to the SDK releases.
	gh release create "${RELEASE_TAG}" --repo "${GITHUB_REPOSITORY}" \
		--verify-tag --latest=false \
		--title "${image} ${version}" \
		--notes-file "${notes_file}"
	echo "Created Release ${RELEASE_TAG} (${DATED_TAG})."
fi
