#!/bin/bash
#
# close-superseded-sync-prs.sh
#
# Keeps at most ONE open upstream-sync PR per base branch. Each mirror-sync run that finds new upstream
# commits opens `<SYNC_PREFIX><sha>`, and every such PR contains everything the previous ones did — so
# without this, stale sync PRs pile up (one per day) and only the newest is worth merging. Run by
# .github/workflows/mirror-sync.yml after the current sync PR exists (or when the base branch already
# contains upstream), it closes the older sync PRs and deletes their branches.
#
# The same script is shared verbatim by the NEMTUS mirrors nemtus/symbol, nemtus/symbol-product and
# nemtus/symbol-networks; keep the copies identical.
#
# A PR is closed only when ALL of these hold:
#   - it targets LOCAL_BRANCH, its head starts with SYNC_PREFIX, and it is not KEEP_BRANCH;
#   - it was opened by the github-actions bot;
#   - its branch carries nothing beyond LOCAL_BRANCH + the current upstream except commits made by the
#     github-actions bot (i.e. the automated sync commit). A sync branch a human has pushed to — e.g. a
#     hand-resolved conflict — is left alone, and so is one whose upstream commits are no longer on
#     upstream (an upstream force-push), since closing it could lose work.
#
# Usage:
#   close-superseded-sync-prs.sh <superseding PR number | base>
#     A PR number: the stale PRs are closed as superseded by that PR (KEEP_BRANCH = its branch).
#     "base":      LOCAL_BRANCH already contains UPSTREAM_REF; stale PRs are closed as already merged.
#
# Environment:
#   LOCAL_BRANCH  (default dev)          base branch of the sync PRs
#   UPSTREAM_REF  (default upstream/dev) local ref of the current upstream head (must be fetched)
#   SYNC_PREFIX   (default sync/upstream-) head-branch prefix of the automated sync PRs
#   KEEP_BRANCH   (default: empty)       sync branch that must never be closed (the current one)
#   DRY_RUN=1                            only report what would be closed
#   GH_REPO / GH_TOKEN                   as for any gh call (mirror-sync.yml sets both)
#
# Failures to close an individual PR are reported as warnings and do not fail the run: the sync PR
# itself is already open, and leaving a stale PR behind is harmless.

set -euo pipefail

SUPERSEDED_BY="${1:?usage: close-superseded-sync-prs.sh <superseding PR number | base>}"
LOCAL_BRANCH="${LOCAL_BRANCH:-dev}"
UPSTREAM_REF="${UPSTREAM_REF:-upstream/dev}"
export SYNC_PREFIX="${SYNC_PREFIX:-sync/upstream-}"  # read by the --jq filter below
KEEP_BRANCH="${KEEP_BRANCH:-}"
DRY_RUN="${DRY_RUN:-}"
BOT_EMAIL='github-actions[bot]@users.noreply.github.com'

git rev-parse --verify --quiet "${UPSTREAM_REF}^{commit}" >/dev/null \
	|| { echo "::error::${UPSTREAM_REF} is not a local ref; fetch upstream first." >&2; exit 2; }
git fetch --no-tags --quiet origin "+refs/heads/${LOCAL_BRANCH}:refs/remotes/origin/${LOCAL_BRANCH}"

if [ "$SUPERSEDED_BY" = 'base' ]; then
	# Without this guard every untouched sync PR would qualify, including the newest one.
	git merge-base --is-ancestor "$UPSTREAM_REF" "refs/remotes/origin/${LOCAL_BRANCH}" \
		|| { echo "::error::'base' mode requires ${LOCAL_BRANCH} to contain ${UPSTREAM_REF}." >&2; exit 2; }
	REASON="\`${LOCAL_BRANCH}\` already contains every upstream commit this PR would merge."
else
	REASON="Superseded by #${SUPERSEDED_BY}, which merges a newer upstream head and contains every upstream commit this PR would merge."
fi

# Open bot-authored sync PRs on LOCAL_BRANCH. `gh` reports the Actions bot as login
# "app/github-actions" with is_bot=true; match loosely so a rename of the login form does not
# silently disable the cleanup.
CANDIDATES="$(gh pr list --base "$LOCAL_BRANCH" --state open --limit 100 \
	--json number,headRefName,author \
	--jq '.[]
		| select(.headRefName | startswith(env.SYNC_PREFIX))
		| select(.author.is_bot and (.author.login | test("github-actions")))
		| "\(.number) \(.headRefName)"')"

if [ -z "$CANDIDATES" ]; then
	echo "No open automated sync PRs to check."
	exit 0
fi

while read -r number branch; do
	if [ -n "$KEEP_BRANCH" ] && [ "$branch" = "$KEEP_BRANCH" ]; then
		continue
	fi

	if ! git fetch --no-tags --quiet origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
		echo "::warning::#${number}: could not fetch ${branch}; leaving it open."
		continue
	fi

	# Commits only this branch has. For an untouched automated sync that is just the bot's merge
	# commit; anything else (a human's commit, upstream history that is gone) means keep it.
	foreign="$(git log --format='%H %ce' "refs/remotes/origin/${branch}" \
		--not "refs/remotes/origin/${LOCAL_BRANCH}" "$UPSTREAM_REF" \
		| awk -v bot="$BOT_EMAIL" '$2 != bot { print $1 }')"
	if [ -n "$foreign" ]; then
		echo "::notice::#${number} (${branch}) has commits not made by the sync bot; leaving it open."
		continue
	fi

	if [ -n "$DRY_RUN" ]; then
		echo "[dry-run] would close #${number} (${branch}) and delete its branch: ${REASON}"
		continue
	fi

	echo "Closing #${number} (${branch}): ${REASON}"
	gh pr comment "$number" --body "${REASON} Closing automatically to keep a single open upstream-sync PR." \
		|| echo "::warning::#${number}: could not post the closing comment."
	gh pr close "$number" --delete-branch \
		|| echo "::warning::#${number}: could not close the PR or delete ${branch}."
done <<<"$CANDIDATES"
