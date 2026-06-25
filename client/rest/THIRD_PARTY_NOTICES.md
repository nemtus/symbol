# Third-Party Notices — symbol-rest image

This file inventories the licenses of what is bundled in the container image built
from `client/rest/Dockerfile.nemtus`. It is provided to support redistribution of that
image. It is informational and not legal advice; see `docs/PUBLISHING-COMPLIANCE.md`
for the publishing checklist.

## 1. symbol-rest (the primary work)

- **License:** GNU Lesser General Public License v3.0 or later (`LGPL-3.0-or-later`).
  Full text bundled at `/app/COPYING.LESSER` (and `/app/LICENSE.txt`).
- **Dual-licensing note:** Per `LICENSE.txt`, source files are LGPL-3.0 *unless a file
  header or a directory `LICENSE` declares the Tech Bureau Commercial License*. The
  image is intended to contain **only LGPL-3.0 sources**; this is enforced by
  `scripts/check-license-scope.sh` (its PASS report is bundled at
  `/app/licenses/LICENSE-SCOPE-REPORT.txt`).
- **Corresponding source (LGPL requirement):** the exact revision is published at
  <https://github.com/nemtus/symbol> and recorded in the image's
  `org.opencontainers.image.revision` label.
- **Copyright:** © Jaguar0625, gimre, BloodyRookie, Tech Bureau, Corp. and contributors.

## 2. Generated code bundled in the source tree

| Path | Origin | License |
|------|--------|---------|
| `src/plugins/rosetta/openApi/**` | generated client from the Rosetta API OpenAPI spec | Apache-2.0 (Rosetta spec © Coinbase) |

`src/plugins/metadata/metal.js` is nemtus/upstream rest code that ships without a
license header; it is LGPL-3.0 like the rest of `src/`.

## 3. npm production dependencies

The image bundles the production dependency tree (`npm install --omit=dev`) under
`/app/node_modules`. These are third-party packages (e.g. `fastify`, `mongodb`,
`zeromq`, `ws`, `symbol-sdk`, `winston`, …) under their own, predominantly permissive
licenses (MIT / Apache-2.0 / ISC / BSD). **Each package keeps its own `LICENSE` file
under `/app/node_modules/<pkg>/`**, and the published image additionally carries an
**SBOM attestation** (attached by buildx) enumerating every package and version. No
hand-maintained aggregate is kept, to avoid drift from the (large, transitive) tree.

## 4. Base image (Ubuntu + Node.js) runtime components

The runtime stage is `ubuntu:24.04` plus `nodejs` from NodeSource and their transitive
runtime libraries (glibc = LGPL-2.1-or-later, libstdc++/libgcc = GPL-3.0-or-later WITH
GCC-Runtime-Library-exception-3.1, `ca-certificates`, `openssl` = Apache-2.0, …). These
are unmodified distribution packages; corresponding source is available from Canonical
(<https://ubuntu.com/legal/open-source-licences>) and NodeSource / the Node.js project.

## 5. Written offer for source

For the copyleft components above (symbol-rest LGPL-3.0 and the Ubuntu GPL/LGPL runtime
libraries), the complete corresponding source can be obtained from each project's
upstream and, for symbol-rest specifically, from <https://github.com/nemtus/symbol> at
the commit named in the image's `org.opencontainers.image.revision` label. Requests may
also be directed to the nemtus maintainers via <https://github.com/nemtus/symbol/issues>.

## 6. Trademarks

"Symbol", "NEM" and related names/logos are the property of their respective owners.
The LGPL grants no trademark rights; this image is an independent build and is not
endorsed by or affiliated with the upstream project owners.
