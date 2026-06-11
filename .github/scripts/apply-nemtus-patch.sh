#!/usr/bin/env bash
#
# apply-nemtus-patch.sh
#
# Idempotently turns an exact mirror of upstream `symbol/symbol` into the
# nemtus rename-republish layer:
#   - sdk/javascript package name -> @nemtus/symbol-sdk (version is left as-is,
#     so it always matches upstream)
#   - publishConfig.access=public (scoped package)
#   - repository / bugs / homepage point at nemtus/symbol
#   - a "mirror" notice is prepended to the root README.md
#
# Running it repeatedly produces the same result. The mirror-sync workflow runs
# it after every `git reset --hard upstream/dev`.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pkg_dir="${repo_root}/sdk/javascript"
readme="${repo_root}/README.md"

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

echo "==> done"
