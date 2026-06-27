#!/usr/bin/env bash
#
# apply-nemtus-patch.sh
#
# Idempotently turns an exact mirror of upstream `symbol/symbol` into the
# nemtus rename-republish layer:
#   - sdk/javascript package name -> @nemtus/symbol-sdk (version is left as-is,
#     so it always matches upstream)
#   - openapi package name -> @nemtus/symbol-openapi (version left as-is too);
#     ships only the bundled spec (openapi3.yml/json + postman.json)
#   - sdk/python PyPI distribution name -> nemtus-symbol-sdk (PyPI has no scopes;
#     the `-python` suffix is dropped to read alongside @nemtus/symbol-sdk on npm.
#     The import module name `symbolchain` is left untouched, and the version is
#     left as-is so it always matches upstream)
#   - catbuffer/parser PyPI distribution name -> nemtus-catparser (import module
#     name `catparser` left untouched; version left as-is)
#   - publishConfig.access=public (scoped packages)
#   - repository / bugs / homepage point at nemtus/symbol
#   - a "mirror" notice is prepended to the root README.md
#   - socket.yml (Socket supply-chain config) is (re)written at the repo root so it
#     survives every upstream sync (Socket is free/unlimited for public repos)
#   - upstream-provided GitHub automation is stripped (we keep only the nemtus
#     workflows), so upstream CI (e.g. codeql-analysis) does not run against the mirror
#   - Dependabot is replaced with a nemtus github-actions-only config (.github/
#     dependabot.yml) that keeps the SHA-pinned actions — including the Socket gate —
#     current, without opening npm/cargo PRs that would diverge from upstream
#
# Running it repeatedly produces the same result. The mirror-sync workflow runs
# it after every upstream merge.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pkg_dir="${repo_root}/sdk/javascript"
openapi_dir="${repo_root}/openapi"
py_sdk_dir="${repo_root}/sdk/python"
py_parser_dir="${repo_root}/catbuffer/parser"
readme="${repo_root}/README.md"

# nemtus-owned GitHub workflows that must survive the strip below.
nemtus_workflows=('publish.yml' 'openapi-publish.yml' 'mirror-sync.yml' 'pinact.yml' 'mirror-ci.yml' 'catapult-image.yml' 'rest-image.yml' 'pypi-sdk-publish.yml' 'pypi-catparser-publish.yml')

echo "==> patching ${pkg_dir}/package.json"
cd "${pkg_dir}"
npm pkg set name='@nemtus/symbol-sdk'
npm pkg set publishConfig.access='public'
# `repository` and `bugs` are strings upstream; overwrite them as scalars so we
# don't depend on their current shape (npm pkg set x.y fails on a string value).
npm pkg delete repository >/dev/null 2>&1 || true
npm pkg set repository.type='git'
npm pkg set repository.url='git+https://github.com/nemtus/symbol.git'
npm pkg set bugs='https://github.com/nemtus/symbol/issues'
npm pkg set homepage='https://github.com/nemtus/symbol/tree/dev/sdk/javascript#readme'
# NOTE: "version" is intentionally NOT modified — it always tracks upstream.

echo "==> patching ${openapi_dir}/package.json"
cd "${openapi_dir}"
npm pkg set name='@nemtus/symbol-openapi'
npm pkg set publishConfig.access='public'
# Upstream declares "Apache 2.0", which is not a valid SPDX identifier (npm warns).
# The bundled spec ships the full Apache-2.0 LICENSE (npm auto-includes it).
npm pkg set license='Apache-2.0'
# Upstream `repository` is already an object {type:git, url, directory:openapi}, so
# only the url needs changing. Set it in place (no delete -> no key reordering),
# which keeps the patch idempotent for the mirror-ci no-drift check.
npm pkg set repository.url='git+https://github.com/nemtus/symbol.git'
npm pkg set bugs='https://github.com/nemtus/symbol/issues'
npm pkg set homepage='https://github.com/nemtus/symbol/tree/dev/openapi#readme'
# Ship ONLY the bundled spec. The publish workflow runs `npm run build` then
# flattens _build/* to the package root, so these names resolve as e.g.
# `@nemtus/symbol-openapi/openapi3.json`. Upstream's "main: index.js" points at
# a non-existent file, so replace it with spec-oriented exports.
npm pkg delete main >/dev/null 2>&1 || true
npm pkg set files[0]='openapi3.yml'
npm pkg set files[1]='openapi3.json'
npm pkg set files[2]='postman.json'
npm pkg set exports['.']='./openapi3.json'
npm pkg set exports['./openapi3.json']='./openapi3.json'
npm pkg set exports['./openapi3.yml']='./openapi3.yml'
npm pkg set exports['./postman.json']='./postman.json'
# NOTE: "version" is intentionally NOT modified — it always tracks upstream.

# sdk/javascript declares "license": "MIT" but upstream ships NO license text and
# asserts NO copyright holder anywhere (the package.json "author" is contact
# metadata, not a copyright statement; upstream's only MIT file leaves the holder
# blank). So we do NOT fabricate a `Copyright (c) <name>` line — that would have us
# author a legal attribution upstream never made. Instead we pass through the MIT
# permission text with a truthful provenance note and an explicit disclaimer that
# the mirror holds no copyright. Only create it when absent — never clobber a
# license upstream might add later. (npm auto-includes a root LICENSE regardless
# of the package's "files".)
sdk_license="${pkg_dir}/LICENSE"
echo "==> ensuring MIT LICENSE in ${sdk_license}"
if [ ! -e "${sdk_license}" ]; then
	cat > "${sdk_license}" <<'EOF'
MIT License

This package is an unmodified redistribution of `symbol-sdk` from the upstream
project symbol/symbol (https://github.com/symbol/symbol), published by its
authors — identified in the upstream package metadata as
"Symbol Contributors <contributors@symbol.dev>" — under the MIT License. The
nemtus mirror asserts no copyright over this software and changes nothing but the
npm package name. The authoritative copyright and license are upstream's.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
	echo "    LICENSE created"
else
	echo "    LICENSE already present (left as-is)"
fi

# Apache-2.0 §4(b): a derivative redistribution must state that files changed.
# The root README notice does not travel inside the @nemtus/symbol-openapi tarball
# (npm ships openapi/README.md), so add an equivalent notice there.
openapi_readme="${openapi_dir}/README.md"
echo "==> ensuring mirror notice in ${openapi_readme}"
if [ -f "${openapi_readme}" ] && ! grep -qF '<!-- nemtus-mirror-notice -->' "${openapi_readme}"; then
	tmp="$(mktemp)"
	cat > "${tmp}" <<'EOF'
<!-- nemtus-mirror-notice -->
> **Note (nemtus mirror):** This package (`@nemtus/symbol-openapi`) is a content
> mirror of the OpenAPI specification from
> [`symbol/symbol`](https://github.com/symbol/symbol) (`openapi/`). The only change
> from upstream is the npm package name; the specification content is unmodified.
> Licensed under Apache-2.0. For the canonical project, see
> [symbol/symbol](https://github.com/symbol/symbol).
<!-- /nemtus-mirror-notice -->

EOF
	cat "${openapi_readme}" >> "${tmp}"
	mv "${tmp}" "${openapi_readme}"
	echo "    notice inserted"
else
	echo "    notice already present or no README"
fi

# --- PyPI mirror layer (sdk/python, catbuffer/parser) ----------------------------
#
# PyPI has no scopes, so the distribution name is a flat unique string. We only
# rewrite the *distribution* name (and repository/description metadata) — the
# import module name (`symbolchain`, `catparser`) is intentionally left untouched,
# matching the "change only the published name" mirror principle. pyproject.toml is
# not npm, so we edit it with anchored sed. The patterns match the EXACT upstream
# lines, so a second run is a no-op (idempotent -> mirror-ci no-drift stays green).
py_sdk_toml="${py_sdk_dir}/pyproject.toml"
echo "==> patching ${py_sdk_toml}"
# name: symbol-sdk-python -> nemtus-symbol-sdk (drop redundant -python on PyPI)
sed -i "s|^name = 'symbol-sdk-python'\$|name = 'nemtus-symbol-sdk'|" "${py_sdk_toml}"
# description: disambiguate from the npm @nemtus/symbol-sdk (same stem, other registry)
sed -i "s|^description = 'Symbol SDK'\$|description = 'Symbol Python SDK (nemtus mirror of upstream symbol-sdk-python; import module: symbolchain)'|" "${py_sdk_toml}"
sed -i "s|^repository = 'https://github.com/symbol/symbol/tree/main/sdk/python'\$|repository = 'https://github.com/nemtus/symbol/tree/dev/sdk/python'|" "${py_sdk_toml}"

py_parser_toml="${py_parser_dir}/pyproject.toml"
echo "==> patching ${py_parser_toml}"
# name: catparser -> nemtus-catparser. The `packages = [{ include = 'catparser' }]`
# line does NOT start with `name = `, so the anchored pattern can't touch it.
sed -i "s|^name = 'catparser'\$|name = 'nemtus-catparser'|" "${py_parser_toml}"
sed -i "s|^repository = 'https://github.com/symbol/symbol/tree/main/catbuffer/parser'\$|repository = 'https://github.com/nemtus/symbol/tree/dev/catbuffer/parser'|" "${py_parser_toml}"

# sdk/python ships NO LICENSE upstream (catbuffer/parser already ships an MIT one,
# which we leave untouched). Mirror the sdk/javascript approach: create an MIT
# LICENSE with a truthful provenance note and a no-copyright disclaimer, only when
# absent — never clobber a license upstream might add later. Poetry includes a
# top-level LICENSE in the sdist/wheel automatically.
py_sdk_license="${py_sdk_dir}/LICENSE"
echo "==> ensuring MIT LICENSE in ${py_sdk_license}"
if [ ! -e "${py_sdk_license}" ]; then
	cat > "${py_sdk_license}" <<'EOF'
MIT License

This package is a redistribution of `symbol-sdk-python` (import module
`symbolchain`) from the upstream project symbol/symbol
(https://github.com/symbol/symbol), published by its authors — identified in the
upstream package metadata as "Symbol Contributors <contributors@symbol.dev>" —
under the MIT License. The nemtus mirror asserts no copyright over this software
and changes nothing but the published PyPI distribution name (to
`nemtus-symbol-sdk`). The authoritative copyright and license are upstream's.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
	echo "    LICENSE created"
else
	echo "    LICENSE already present (left as-is)"
fi

# The root README notice does not travel inside the PyPI sdist (PyPI ships each
# package's own README), so prepend an equivalent notice to each package README.
# The sdk/python notice also states the distribution-name change explicitly, so a
# reader can't confuse `nemtus-symbol-sdk` (PyPI, Python) with @nemtus/symbol-sdk
# (npm, JavaScript).
py_sdk_readme="${py_sdk_dir}/README.md"
echo "==> ensuring mirror notice in ${py_sdk_readme}"
if [ -f "${py_sdk_readme}" ] && ! grep -qF '<!-- nemtus-mirror-notice -->' "${py_sdk_readme}"; then
	tmp="$(mktemp)"
	cat > "${tmp}" <<'EOF'
<!-- nemtus-mirror-notice -->
> **Note (nemtus mirror):** This package is a content mirror of the **Python** SDK
> from [`symbol/symbol`](https://github.com/symbol/symbol) (`sdk/python`, upstream
> PyPI name `symbol-sdk-python`). nemtus republishes it on PyPI as
> [`nemtus-symbol-sdk`](https://pypi.org/project/nemtus-symbol-sdk/); the only
> change from upstream is the published distribution name. The import module name
> is unchanged — you still `import symbolchain`. This is distinct from
> `@nemtus/symbol-sdk` on npm, which mirrors the JavaScript SDK. For the canonical
> project, see [symbol/symbol](https://github.com/symbol/symbol).
<!-- /nemtus-mirror-notice -->

EOF
	cat "${py_sdk_readme}" >> "${tmp}"
	mv "${tmp}" "${py_sdk_readme}"
	echo "    notice inserted"
else
	echo "    notice already present or no README"
fi

py_parser_readme="${py_parser_dir}/README.md"
echo "==> ensuring mirror notice in ${py_parser_readme}"
if [ -f "${py_parser_readme}" ] && ! grep -qF '<!-- nemtus-mirror-notice -->' "${py_parser_readme}"; then
	tmp="$(mktemp)"
	cat > "${tmp}" <<'EOF'
<!-- nemtus-mirror-notice -->
> **Note (nemtus mirror):** This package is a content mirror of the catbuffer
> parser from [`symbol/symbol`](https://github.com/symbol/symbol)
> (`catbuffer/parser`, upstream PyPI name `catparser`). nemtus republishes it on
> PyPI as [`nemtus-catparser`](https://pypi.org/project/nemtus-catparser/); the
> only change from upstream is the published distribution name. The import module
> name is unchanged — you still `import catparser`. For the canonical project, see
> [symbol/symbol](https://github.com/symbol/symbol).
<!-- /nemtus-mirror-notice -->

EOF
	cat "${py_parser_readme}" >> "${tmp}"
	mv "${tmp}" "${py_parser_readme}"
	echo "    notice inserted"
else
	echo "    notice already present or no README"
fi
# --- end PyPI mirror layer -------------------------------------------------------

echo "==> ensuring mirror notice in ${readme}"
notice_marker='<!-- nemtus-mirror-notice -->'
if ! grep -qF "${notice_marker}" "${readme}"; then
	tmp="$(mktemp)"
	cat > "${tmp}" <<'EOF'
<!-- nemtus-mirror-notice -->
> **Note (nemtus mirror):** This repository is a content mirror of
> [`symbol/symbol`](https://github.com/symbol/symbol). It exists only to
> republish the upstream `symbol-sdk` package under the scoped name
> [`@nemtus/symbol-sdk`](https://www.npmjs.com/package/@nemtus/symbol-sdk) with
> matching version numbers. There are no source-level differences from upstream
> other than the npm package name. For the canonical project, see
> [symbol/symbol](https://github.com/symbol/symbol).
<!-- /nemtus-mirror-notice -->

EOF
	cat "${readme}" >> "${tmp}"
	mv "${tmp}" "${readme}"
	echo "    notice inserted"
else
	echo "    notice already present"
fi

# Socket (https://socket.dev) supply-chain config. Owned by the nemtus layer and
# rewritten verbatim each run so it always survives an upstream sync and the
# mirror-ci no-drift check stays green. Keep this heredoc byte-identical to the
# committed socket.yml.
socket_yml="${repo_root}/socket.yml"
echo "==> writing ${socket_yml}"
cat > "${socket_yml}" <<'EOF'
# socket.yml — Socket (https://socket.dev) configuration for the nemtus/symbol mirror.
#
# Managed by the nemtus republish layer: .github/scripts/apply-nemtus-patch.sh
# rewrites this file verbatim on every upstream sync, so edit it THERE, not here —
# otherwise the next mirror-sync reverts your change, and mirror-ci.yml's no-drift
# check fails when this file and the script disagree.
#
# Socket is free and unlimited for public/open-source repos, so this adds supply
# chain scanning at zero cost. Scope: every dependency manifest in the monorepo —
# npm (sdk/javascript, openapi, client/rest), Python (sdk/python, catbuffer/parser),
# Rust/WASM (sdk/javascript/wasm) and C/C++ (client/catapult: conanfile.py, vcpkg.json).
version: 2

# Run a PR scan only when a dependency manifest actually changes (gitignore-style
# globs matched against the PR's changed files). The daily mirror-sync PR bumps these.
triggerPaths:
  - '**/package.json'
  - '**/package-lock.json'
  - '**/pyproject.toml'
  - '**/*requirements*.txt'   # requirements.txt, dev_requirements.txt, lint_requirements.txt
  - '**/poetry.lock'
  - '**/Cargo.toml'
  - '**/Cargo.lock'
  - '**/conanfile.py'
  - '**/vcpkg.json'

# High-signal supply-chain alerts for a mirror that ingests upstream deps daily.
# issueRules is coarse (on/off per alert type); fine-grained block-vs-warn tuning
# lives in the Socket dashboard, and the required-status-check branch-protection rule
# is what turns a failing scan into a hard merge block. Only documented slugs are
# used here to avoid silently breaking the config.
issueRules:
  malware: true
  installScripts: true
  didYouMean: true     # typosquats
  gitDependency: true
  telemetry: false     # noisy for a crypto/blockchain dep tree; left to the dashboard

githubApp:
  enabled: true
  pullRequestAlertsEnabled: true
  # Do NOT list the mirror-sync bot here: its automated PRs are exactly what we scan.
  ignoreUsers: []
EOF

echo "==> stripping upstream GitHub automation (keeping only nemtus workflows)"
workflows_dir="${repo_root}/.github/workflows"
if [ -d "${workflows_dir}" ]; then
	keep_args=()
	for wf in "${nemtus_workflows[@]}"; do
		keep_args+=(! -name "${wf}")
	done
	# Remove every workflow file except the nemtus-owned ones (covers upstream's
	# codeql-analysis.yaml, combine-dependabot-pr.yaml, and anything added later).
	find "${workflows_dir}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
		"${keep_args[@]}" -print -delete
fi
# Dependabot: replace upstream's multi-ecosystem config (npm/cargo/github-actions —
# the npm/cargo updates would open PRs that diverge the mirror from upstream) with a
# nemtus-owned github-actions-ONLY config. This keeps the SHA-pinned actions current,
# including SocketDev/action (our supply-chain gate), behind a reviewed PR. Owned by
# this script and rewritten verbatim, so it survives every sync (matches the committed
# file -> mirror-ci no-drift check stays green). Remove upstream's .yaml so only ours
# (.yml) remains (GitHub errors if both exist).
rm -f "${repo_root}/.github/dependabot.yaml"
dependabot_yml="${repo_root}/.github/dependabot.yml"
echo "==> writing ${dependabot_yml}"
cat > "${dependabot_yml}" <<'EOF'
# Dependabot — nemtus mirror layer. Owned by .github/scripts/apply-nemtus-patch.sh,
# which rewrites this file verbatim on every upstream sync (mirror-ci.yml enforces no
# drift). Edit it THERE, not here.
#
# Scoped to github-actions ONLY: it keeps our SHA-pinned actions current — including
# SocketDev/action, the supply-chain gate — behind a human-reviewed PR, while pinact.yml
# re-asserts SHA pinning. We deliberately do NOT enable npm/cargo/pip updates: this is a
# mirror whose package deps track upstream symbol/symbol, so dependency PRs against them
# would diverge the mirror from upstream.
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    target-branch: dev
    schedule:
      interval: weekly
      day: sunday
    labels: [dependencies]
    commit-message:
      prefix: '[dependency]'
    # Buffer so a freshly published action release has time to surface regressions
    # before Dependabot proposes it (Socket's recommended cooldown).
    cooldown:
      semver-major-days: 14
      semver-minor-days: 7
      semver-patch-days: 3
    groups:
      github-actions:
        patterns:
          - '*'
EOF

echo "==> done"
