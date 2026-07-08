#!/usr/bin/env bash
#
# relock-sdk.sh
#
# Regenerate sdk/javascript/package-lock.json after apply-nemtus-patch.sh has repointed
# the crypto-wasm optional dependency at the nemtus mirror
# (symbol-crypto-wasm-node -> npm:@nemtus/symbol-crypto-wasm-node). The aliased
# package.json and the lockfile must agree, or `npm ci` in mirror-ci.yml / publish.yml
# fails (or silently installs upstream's package).
#
# npm's `--package-lock-only` reuses an existing lockfile node when its version still
# satisfies the range, so it does NOT re-point an already-present same-version entry to
# the alias target. We therefore drop that one entry first, which forces npm to
# re-resolve it against @nemtus/symbol-crypto-wasm-node; every other entry is left
# untouched, keeping the diff minimal.
#
# Run by mirror-sync.yml (which has network) right after apply-nemtus-patch.sh. It is
# deliberately NOT part of apply-nemtus-patch.sh: that script must stay offline and
# lockfile-free so mirror-ci.yml's verify-rename-layer no-drift check (which runs the
# patch without a network regen) stays valid.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}/sdk/javascript"

# Drop the crypto-wasm lockfile node so the alias is resolved fresh (see header).
node -e 'const fs=require("fs"),f="package-lock.json";const j=JSON.parse(fs.readFileSync(f));if(j.packages)delete j.packages["node_modules/symbol-crypto-wasm-node"];fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");'

# Rewrite the lockfile from package.json without touching node_modules or running
# install scripts. npm normalizes formatting, so the committed lockfile stays canonical.
npm install --package-lock-only --ignore-scripts
