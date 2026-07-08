#!/usr/bin/env bash
#
# build-crypto-wasm.sh <variant: web|node|bundler> <version> <out_dir>
#
# nemtus republish layer for the Symbol crypto WASM packages. Upstream builds a
# single Rust crate (sdk/javascript/wasm, crate name `symbol-crypto-wasm`) into
# three separately-named npm packages via wasm-pack targets:
#
#   variant   wasm-pack --target   npm package                        consumers
#   -------   ------------------   --------------------------------   -------------------------
#   web       web                  @nemtus/symbol-crypto-wasm-web     browser / webpack SPA
#   bundler   bundler              @nemtus/symbol-crypto-wasm-bundler Vite / Rollup / modern SPA
#   node      nodejs               @nemtus/symbol-crypto-wasm-node    Node / SSR (also the SDK dep)
#
# This script builds ONE variant and turns wasm-pack's generated package (named
# after the crate, `symbol-crypto-wasm`, versioned from Cargo.toml `0.1.0`) into
# the scoped nemtus mirror package: only the npm name, version and repository
# metadata change; the compiled wasm + JS glue are unmodified. The <version> is
# passed in (the publish workflow mirrors upstream's npm version) — it is NOT read
# from Cargo.toml, because the published wasm packages are versioned independently
# of the crate.
#
# No `--out-name` is passed, so wasm-pack keeps the crate-derived file stem
# `symbol_crypto_wasm` (=> `symbol_crypto_wasm.js` + `symbol_crypto_wasm_bg.wasm`),
# matching upstream's packages and the import path documented in
# sdk/javascript/README.md (`.../symbol-crypto-wasm-web/symbol_crypto_wasm.js`).
#
# Idempotent: re-running against a fresh <out_dir> produces the same result.
set -euo pipefail

variant="${1:?usage: build-crypto-wasm.sh <web|node|bundler> <version> <out_dir>}"
version="${2:?usage: build-crypto-wasm.sh <web|node|bundler> <version> <out_dir>}"
out_dir="${3:?usage: build-crypto-wasm.sh <web|node|bundler> <version> <out_dir>}"

case "${variant}" in
	web)     wasm_target='web' ;;
	bundler) wasm_target='bundler' ;;
	node)    wasm_target='nodejs' ;;
	*) echo "::error::unknown variant '${variant}' (expected web|node|bundler)" >&2; exit 1 ;;
esac

pkg_name="@nemtus/symbol-crypto-wasm-${variant}"
repo_root="$(git rev-parse --show-toplevel)"
crate_dir="${repo_root}/sdk/javascript/wasm"

# Resolve out_dir to an absolute path before we cd into the crate (wasm-pack's
# --out-dir is relative to the crate dir otherwise).
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"

echo "==> building ${pkg_name}@${version} (wasm-pack --target ${wasm_target}) -> ${out_dir}"
(
	cd "${crate_dir}"
	# --release: optimized build; --no-typescript: matches upstream/build.sh (the
	# published packages ship no .d.ts). No --out-name: keep the `symbol_crypto_wasm`
	# stem so the output is drop-in compatible with upstream.
	wasm-pack build --release --no-typescript --target "${wasm_target}" --out-dir "${out_dir}"
)

# wasm-pack drops a .gitignore in the out dir; harmless, but remove it so it can't
# be mistaken for repo content (this dir is a throwaway build artifact).
rm -f "${out_dir}/.gitignore"

echo "==> stamping nemtus mirror metadata onto ${out_dir}/package.json"
(
	cd "${out_dir}"
	# wasm-pack writes name="symbol-crypto-wasm", version=<Cargo.toml>. Override the
	# published identity; leave the wasm-pack `files`/`main`/`module`/`collaborators`
	# fields intact (they describe the actual artifact and its authorship).
	npm pkg set name="${pkg_name}"
	npm pkg set version="${version}"
	npm pkg set description="Symbol crypto WASM (${variant} build) — nemtus mirror of symbol-crypto-wasm-${variant}; only the npm package name differs from upstream."
	npm pkg set license='MIT'
	npm pkg set publishConfig.access='public'
	npm pkg set repository.type='git'
	npm pkg set repository.url='git+https://github.com/nemtus/symbol.git'
	npm pkg set bugs='https://github.com/nemtus/symbol/issues'
	npm pkg set homepage='https://github.com/nemtus/symbol/tree/dev/sdk/javascript/wasm#readme'
)

# MIT LICENSE — mirror sdk/javascript's stance exactly: the crate declares NO
# `license` field and NO copyright holder (Cargo.toml `authors` is contact
# metadata, not a copyright statement), so we do NOT fabricate a `Copyright (c)`
# line. We pass through the MIT permission text with a truthful provenance note and
# an explicit disclaimer that the mirror holds no copyright. npm auto-includes a
# LICENSE regardless of the package's "files".
echo "==> writing ${out_dir}/LICENSE"
cat > "${out_dir}/LICENSE" <<EOF
MIT License

This package is an unmodified redistribution of the Symbol crypto WASM \`${wasm_target}\`
build (upstream npm package \`symbol-crypto-wasm-${variant}\`) compiled from the
\`symbol-crypto-wasm\` Rust crate in the upstream project symbol/symbol
(https://github.com/symbol/symbol), authored by its contributors — identified in
the upstream crate metadata as "Symbol Contributors <contributors@symbol.dev>".
The nemtus mirror asserts no copyright over this software and changes nothing but
the npm package name. The authoritative copyright and license are upstream's.

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

# The root repo README notice does not travel inside the npm tarball, so ship a
# per-package mirror notice. wasm-pack may have generated a default README; we
# overwrite it with the nemtus notice.
echo "==> writing ${out_dir}/README.md"
cat > "${out_dir}/README.md" <<EOF
<!-- nemtus-mirror-notice -->
# ${pkg_name}

> **Note (nemtus mirror):** This package is a content mirror of the Symbol crypto
> WASM \`${wasm_target}\` build from
> [\`symbol/symbol\`](https://github.com/symbol/symbol) (\`sdk/javascript/wasm\`,
> upstream npm name \`symbol-crypto-wasm-${variant}\`). The only change from upstream
> is the npm package name; the compiled WebAssembly and JavaScript glue are
> unmodified. It provides the Ed25519 crypto used by
> [\`@nemtus/symbol-sdk\`](https://www.npmjs.com/package/@nemtus/symbol-sdk).
> For the canonical project, see
> [symbol/symbol](https://github.com/symbol/symbol).
<!-- /nemtus-mirror-notice -->

This build is produced with \`wasm-pack build --target ${wasm_target}\` and exposes
\`symbol_crypto_wasm.js\` + \`symbol_crypto_wasm_bg.wasm\` at the package root, matching
upstream's layout.
EOF

echo "==> done: ${pkg_name}@${version} staged in ${out_dir}"
