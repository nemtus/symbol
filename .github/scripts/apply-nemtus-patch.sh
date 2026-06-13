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
#   - publishConfig.access=public (scoped packages)
#   - repository / bugs / homepage point at nemtus/symbol
#   - a "mirror" notice is prepended to the root README.md
#   - upstream-provided GitHub automation is stripped (we keep only the nemtus
#     workflows), so upstream CI (e.g. codeql-analysis) and Dependabot do not run
#     against the mirror.
#
# Running it repeatedly produces the same result. The mirror-sync workflow runs
# it after every upstream merge.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pkg_dir="${repo_root}/sdk/javascript"
openapi_dir="${repo_root}/openapi"
readme="${repo_root}/README.md"

# nemtus-owned GitHub workflows that must survive the strip below.
nemtus_workflows=('publish.yml' 'openapi-publish.yml' 'mirror-sync.yml' 'pinact.yml' 'mirror-ci.yml')

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
# Upstream Dependabot config would open dependency PRs against the mirror; remove it.
rm -f "${repo_root}/.github/dependabot.yaml" "${repo_root}/.github/dependabot.yml"

echo "==> done"
