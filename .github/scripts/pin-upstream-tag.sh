#!/usr/bin/env bash
#
# pin-upstream-tag.sh
#
# Roll ONE package directory back to the upstream `symbol/symbol` release tag that
# corresponds to the version about to be published, so a republished version number
# always ships the upstream tree that carries that number.
#
# WHY THIS EXISTS
# ---------------
# The publish workflows are triggered by a push to `dev` that changed a package
# manifest, and they check out `${{ github.sha }}` — the merged dev commit. dev is a
# running merge of upstream/dev, so by the time a mirror-sync PR is merged the tree can
# already be many commits PAST the upstream tag that introduced the version bump. Those
# extra commits are usually unrelated (docs, catapult, jenkins), but they can also carry
# dependency bumps inside the package directory. Publishing from dev HEAD then produces
# a tarball labelled e.g. 3.3.3 whose dependency ranges differ from upstream's own
# 3.3.3 — a silent divergence for a mirror whose entire contract is "same content,
# different package name".
#
# Observed instance: upstream tag sdk/javascript/v3.3.3 declares
# `@noble/hashes: ~2.3.0`, but upstream/dev three weeks later declares `~2.4.0`
# (plus webpack/mocha/eslint devDependency bumps that change the built dist/ bundle).
#
# WHAT IT DOES
# ------------
#   1. Derives the upstream tag from the package directory and the version:
#        <pkg_dir>/v<base_version>      e.g. sdk/javascript/v3.3.3
#      A PEP 440 `.postN` suffix (a nemtus-only repackage of the SAME upstream source)
#      is stripped for tag lookup and restored afterwards.
#   2. Fetches that tag from upstream (shallow, anonymous, no tags written).
#   3. Verifies the manifest AT THE TAG declares exactly <base_version> — proof that the
#      tag really marks the release of this version.
#   4. Replaces <pkg_dir> in the working tree with the tag's tree.
#   5. Restores the `.postN` version string when one was stripped.
#
# It deliberately does NOT re-apply the nemtus rename layer: step 4 necessarily reverts
# it (the layer does not exist upstream), and the caller runs apply-nemtus-patch.sh
# afterwards to put it back — plus, for sdk/javascript, relock-sdk.sh, because the tag's
# lockfile is upstream's un-aliased one and must be re-resolved against
# @nemtus/symbol-crypto-wasm-node.
#
# MODES
#   strict  Cannot identify the upstream release tree -> FAIL, publish nothing.
#           For the two SDKs, which upstream tags reliably at the bump commit and which
#           real dependents install.
#   warn    Cannot identify it -> emit ::warning:: and leave the tree at dev HEAD.
#           For `openapi` and `catbuffer/parser`, where upstream's tagging does not
#           support pinning at all:
#             - openapi 1.0.5 and catparser 3.2.0 were released with NO tag ever pushed
#               (both were published from dev HEAD for exactly that reason);
#             - `openapi/v1.0.4` points at a commit whose openapi/package.json already
#               says 1.0.5, i.e. the tag was pushed after the next bump;
#             - `catbuffer/parser/v3.1.0` predates catbuffer/parser/pyproject.toml, so
#               there is no manifest to verify against.
#           strict on these would freeze both packages permanently, so they degrade to
#           today's behaviour with the divergence made explicit in the run summary.
#
# In BOTH modes the script never pins a tree it could not verify. The only difference is
# whether an unverifiable tag stops the publish or merely annotates it.
#
# USAGE
#   pin-upstream-tag.sh [--verify-only] <pkg_dir> <version> <strict|warn>
#
#   --verify-only  Resolve and verify the tag but do not touch the working tree. Used
#                  by the `check` job so an unresolvable tag fails BEFORE the
#                  npm-production / pypi-production approval prompt is raised.
#
# Writes `upstream_tag=<tag>` to $GITHUB_OUTPUT (empty when warn mode could not resolve
# one) and a short report to $GITHUB_STEP_SUMMARY. Both are optional, so the script runs
# locally as-is.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/symbol/symbol.git}"

verify_only=false
if [ "${1:-}" = '--verify-only' ]; then
	verify_only=true
	shift
fi

if [ "$#" -ne 3 ]; then
	echo "usage: $(basename "$0") [--verify-only] <pkg_dir> <version> <strict|warn>" >&2
	exit 2
fi

pkg_dir="$1"
version="$2"
mode="$3"

case "${mode}" in
	strict | warn) ;;
	*)
		echo "::error::unknown mode '${mode}' (expected strict or warn)" >&2
		exit 2
		;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

if [ ! -d "${pkg_dir}" ]; then
	echo "::error::package directory '${pkg_dir}' does not exist" >&2
	exit 1
fi

# Locate the manifest that carries the version. Exactly one of these exists per
# package directory in this repo (npm: package.json, poetry: pyproject.toml).
if [ -f "${pkg_dir}/package.json" ]; then
	manifest="${pkg_dir}/package.json"
	manifest_kind=npm
elif [ -f "${pkg_dir}/pyproject.toml" ]; then
	manifest="${pkg_dir}/pyproject.toml"
	manifest_kind=poetry
else
	echo "::error::no package.json or pyproject.toml under '${pkg_dir}'" >&2
	exit 1
fi

# Read a version out of a manifest blob on stdin, without touching the working tree.
# Exits non-zero when the blob is not a manifest of the expected shape.
read_manifest_version() {
	case "${manifest_kind}" in
		npm) node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s).version;if(!v)process.exit(1);console.log(v)}catch{process.exit(1)}})' ;;
		# stderr is discarded on both: an unparsable/absent manifest is an expected
		# outcome here (see `unresolvable`), not a crash worth printing a traceback for.
		poetry) python3 -c 'import sys,tomllib;d=tomllib.loads(sys.stdin.read());print(d["tool"]["poetry"]["version"])' 2>/dev/null ;;
	esac
}

report() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$1" >> "${GITHUB_STEP_SUMMARY}"
	fi
	printf '%s\n' "$1"
}

set_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
	fi
}

# Strip a nemtus-only `.postN` repackage suffix: it never exists upstream, so the tag
# to look up is the base version. Anything else is passed through untouched.
base_version="${version}"
post_suffix=''
if [[ "${version}" =~ ^(.+)(\.post[0-9]+)$ ]]; then
	base_version="${BASH_REMATCH[1]}"
	post_suffix="${BASH_REMATCH[2]}"
fi

tag="${pkg_dir}/v${base_version}"

# Single exit point for "the upstream release tree cannot be identified". strict stops
# the publish; warn annotates it and leaves the tree at dev HEAD. Never pins on a guess.
unresolvable() {
	local reason="$1"
	if [ "${mode}" = 'strict' ]; then
		report "### upstream tag pin: FAILED

${reason}

Refusing to publish \`${version}\` from dev HEAD — that would ship a version number
whose content upstream never released under that number. Once upstream publishes a
correct \`${tag}\`, re-run this workflow via workflow_dispatch."
		echo "::error::cannot pin ${pkg_dir} to ${tag}: ${reason} Refusing to publish ${version} from dev HEAD (mode=strict)." >&2
		exit 1
	fi
	report "### upstream tag pin: SKIPPED

${reason}

Publishing \`${version}\` from the dev tree instead (mode=warn). Upstream does not tag
this package in a way that supports pinning, so this is expected — but the published
content may include upstream commits made after the version bump."
	echo "::warning::cannot pin ${pkg_dir} to ${tag}: ${reason} Publishing ${version} from dev HEAD (mode=warn)."
	set_output upstream_tag ''
	exit 0
}

echo "==> resolving upstream tag ${tag} for ${manifest} (version ${version}, mode ${mode})"

# Anonymous shallow fetch of the single tag. --no-tags keeps refs/tags/ clean; the
# commit lands in FETCH_HEAD. A public URL needs no credentials, which is why the
# publish jobs can keep persist-credentials: false.
if ! git fetch --quiet --no-tags --depth 1 "${UPSTREAM_URL}" "refs/tags/${tag}" 2>/dev/null; then
	unresolvable "Upstream tag \`${tag}\` does not exist."
fi

upstream_sha="$(git rev-parse FETCH_HEAD)"

if ! tag_version="$(git show "FETCH_HEAD:${manifest}" 2>/dev/null | read_manifest_version)"; then
	unresolvable "Upstream tag \`${tag}\` (\`${upstream_sha}\`) has no readable \`${manifest}\`."
fi

# The tag must actually declare the version we are publishing. Upstream has pushed tags
# at commits that already carry the NEXT version (openapi/v1.0.4 -> 1.0.5), so this is a
# real guard, not a formality: pinning to such a tag would publish the wrong tree.
if [ "${tag_version}" != "${base_version}" ]; then
	unresolvable "Upstream tag \`${tag}\` (\`${upstream_sha}\`) declares \`${tag_version}\` in \`${manifest}\`, not \`${base_version}\`."
fi

set_output upstream_tag "${tag}"

if [ "${verify_only}" = true ]; then
	report "### upstream tag pin: verified

\`${tag}\` (\`${upstream_sha}\`) declares ${manifest_kind} version \`${base_version}\` — publish will build \`${pkg_dir}\` from that tree."
	exit 0
fi

# Everything the pin changes, for the record. This intentionally includes the nemtus
# rename layer being reverted (apply-nemtus-patch.sh puts it back in the next step);
# what matters for review is the upstream-side drift listed alongside it.
rolled_back="$(git diff --stat "HEAD" "${upstream_sha}" -- "${pkg_dir}" || true)"

# Replace the directory wholesale rather than checking out over it: `git checkout
# <commit> -- <path>` only writes paths that exist in <commit>, so a file dev has and
# the tag does not would survive and end up in the published tarball.
rm -rf "${pkg_dir}"
git checkout "${upstream_sha}" -- "${pkg_dir}"

# Restore the nemtus `.postN` repackage suffix stripped for the tag lookup, so the
# published version is the one the check job compared against the registry.
if [ -n "${post_suffix}" ]; then
	echo "==> restoring post-release version ${version}"
	case "${manifest_kind}" in
		npm) (cd "${pkg_dir}" && npm pkg set "version=${version}") ;;
		poetry)
			python3 - "${repo_root}/${manifest}" "${base_version}" "${version}" <<'PY'
import pathlib
import re
import sys

path, base, full = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
# Anchored at line start so only the [tool.poetry] `version = ` key is touched,
# never a dependency constraint that happens to contain the same string.
patched, n = re.subn(
    rf"(?m)^version = (['\"]){re.escape(base)}\1$",
    f"version = '{full}'",
    text,
)
if n != 1:
    sys.exit(f"expected exactly one `version = {base}` line in {path}, found {n}")
path.write_text(patched)
PY
			;;
	esac
fi

report "### upstream tag pin: applied

\`${pkg_dir}\` now holds the upstream tree at \`${tag}\` (\`${upstream_sha}\`) instead of dev HEAD.
The diff below is what that replaced — it covers both the nemtus rename layer (re-applied
in the next step) and any upstream drift after the tag, which is what this pin exists to
keep out of the release:

\`\`\`
${rolled_back:-(dev HEAD was already identical to the tag)}
\`\`\`"

echo "==> done"
