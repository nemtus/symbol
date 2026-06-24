# Third-Party Notices — catapult-server self-contained image

This file inventories the licenses of everything bundled in the container image
built from `client/catapult/Dockerfile.selfcontained`. It is provided to support
redistribution of that image. It is informational and not legal advice; see
`docs/PUBLISHING-COMPLIANCE.md` for the publishing checklist.

## 1. catapult-server (the primary work)

- **License:** GNU Lesser General Public License v3.0 or later (`LGPL-3.0-or-later`).
  Full text bundled at `/opt/catapult/licenses/LGPL-3.0.txt` (repo: `COPYING.LESSER`).
- **Dual-licensing note:** Per `LICENSE.txt`, source files are LGPL-3.0 *unless a file
  header or a directory `LICENSE` declares the Tech Bureau Commercial License*. The
  build in this image is intended to contain **only LGPL-3.0 sources**; verification of
  that scope is part of `docs/PUBLISHING-COMPLIANCE.md`.
- **Corresponding source (LGPL requirement):** the exact revision is published at
  <https://github.com/nemtus/symbol> and recorded in the image's
  `org.opencontainers.image.revision` label. Any nemtus modifications are in that public
  fork under LGPL-3.0.
- **Copyright:** © Jaguar0625, gimre, BloodyRookie, Tech Bureau, Corp. and contributors.

## 2. Bundled native dependencies (built from canonical upstream sources)

Versions are locked in `jenkins/catapult/versions.properties`.

| Component | Upstream | License | Notes |
|-----------|----------|---------|-------|
| Boost | https://www.boost.org | BSL-1.0 | permissive |
| OpenSSL | https://github.com/openssl/openssl | Apache-2.0 | 3.x |
| RocksDB | https://github.com/facebook/rocksdb | GPL-2.0 **OR** Apache-2.0 (dual) | **Apache-2.0 elected** for this distribution |
| mongo-c-driver | https://github.com/mongodb/mongo-c-driver | Apache-2.0 | |
| mongo-cxx-driver | https://github.com/mongodb/mongo-cxx-driver | Apache-2.0 | |
| libzmq | https://github.com/zeromq/libzmq | MPL-2.0 | file-level copyleft; unmodified |
| cppzmq | https://github.com/zeromq/cppzmq | MIT | header-only |
| ed25519-donna | bundled in `client/catapult/external/donna` | Public Domain | by Andrew Moon |

> GoogleTest and Google Benchmark (Apache-2.0) are build/test-only and are **not**
> present in the runtime image.

## 3. Base image (Ubuntu) runtime components

The runtime stage installs, from the Ubuntu archive: `libstdc++6`, `libgcc-s1`
(GPL-3.0-or-later **WITH** GCC-Runtime-Library-exception-3.1), `libatomic1` (same),
`glibc` (LGPL-2.1-or-later), `ca-certificates`, `openssl` (Apache-2.0) and their
transitive runtime dependencies. These are unmodified Ubuntu packages; their
corresponding source is available from Canonical
(<https://ubuntu.com/legal/open-source-licences>) and via `apt-get source` on the
matching Ubuntu release.

## 4. Written offer for source

For the copyleft components above (catapult-server LGPL-3.0, libzmq MPL-2.0, and the
Ubuntu GPL/LGPL runtime libraries), the complete corresponding source can be obtained
from each project's upstream listed here and, for catapult-server specifically, from
<https://github.com/nemtus/symbol> at the commit named in the image's
`org.opencontainers.image.revision` label. Requests may also be directed to the nemtus
maintainers via <https://github.com/nemtus/symbol/issues>.

## 5. Trademarks

"Symbol", "NEM", "Catapult" and related names/logos are the property of their
respective owners. The LGPL grants no trademark rights; this image is an independent
build and is not endorsed by or affiliated with the upstream project owners.
