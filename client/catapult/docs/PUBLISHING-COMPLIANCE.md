# Publishing-compliance — catapult-server image

catapult-server is **published as a public container image** from
`client/catapult/Dockerfile.selfcontained`. Compliance is enforced and evidenced
**automatically** by CI/CD — while the gate is green there is **no per-release manual
step**. This document explains what is automated, what evidence is produced, and the
one exception that needs a human. It is engineering guidance, **not legal advice**;
because a third party (Tech Bureau, Corp.) holds copyright and the source is
dual-licensed, the automated `check-license-scope.sh` gate (Section 1) is the agreed,
recorded standard that no commercial-licensed code is shipped.

**How it is automated (no manual work on the green path):**
1. `check-license-scope.sh` runs as a CI step **and** inside the Dockerfile, hard-blocking
   any build/publish if a commercial-licensed file appears (Section 1).
2. The PASS report is bundled in the image at
   `/opt/catapult/licenses/LICENSE-SCOPE-REPORT.txt`, and an SBOM + SLSA provenance
   attestation is attached to the published image.
3. `.github/workflows/catapult-image.yml` records revision + image digest + gate result
   to the workflow run summary on every publish.

A human is needed **only** in the exception case where the gate fails — then publishing
is blocked and Section 6/7 apply.

## 1. The licensing gate (the only blocker)

`client/catapult/LICENSE.txt` states each source file is **LGPL-3.0** *unless its header
or a directory `LICENSE` declares the **Tech Bureau Commercial License***. Publishing is
only permissible if the built binaries contain **no commercial-licensed source**.

Verify with the single source-of-truth scanner (also run by
`.github/workflows/catapult-image.yml`, where it hard-blocks publishing on failure):

```sh
bash client/catapult/scripts/check-license-scope.sh
```

It checks three things and exits non-zero on any finding: (1) no directory-level LICENSE
other than the root `COPYING.LESSER`/`LICENSE.txt`; (2) no source contains
`tech bureau commercial`/`commercial license`/`proprietary`/`confidential`; (3) every
compiled source carries the LGPL header, except `external/donna` (ed25519-donna, Public
Domain). As of the last check this tree is **all LGPL-3.0** (0 commercial-licensed files).
Re-run on the exact revision being published — the dual-license clause means commercial
files *could* appear after an upstream sync.

- [ ] `check-license-scope.sh` re-run on the exact revision being published; output recorded.
- [ ] `resources/` reviewed (config templates; data, not commercial-licensed code).

## 2. LGPL-3.0 obligations (mechanical — already wired into the image)

- [x] LGPL text shipped in image at `/opt/catapult/licenses/LGPL-3.0.txt`.
- [x] `LICENSE.txt` + `THIRD_PARTY_NOTICES.md` shipped under `/opt/catapult/licenses/`.
- [x] Corresponding-source pointer: `org.opencontainers.image.source` +
      `org.opencontainers.image.revision` labels point at the public nemtus commit.
- [ ] Confirm the published revision is actually pushed/public on `github.com/nemtus/symbol`.
- [ ] Any nemtus modifications to catapult source are disclosed under LGPL in that fork.
- Relinking clause: satisfied — catapult is shipped as its own LGPL work with
  dynamically-linked dependencies and public source (no proprietary static combination).

## 3. Bundled-dependency notices

- [x] `THIRD_PARTY_NOTICES.md` inventories Boost/OpenSSL/RocksDB/mongo-c/mongo-cxx/
      libzmq/cppzmq/ed25519-donna + Ubuntu base components.
- [x] RocksDB dual license: **Apache-2.0 elected** and stated.
- [ ] Confirm test-only deps (gtest, benchmark) are absent from the runtime image
      (`docker run --rm --entrypoint sh IMAGE -c 'ls /opt/catapult/deps'`).

## 4. Trademark

- [ ] Image named neutrally (e.g. `ghcr.io/nemtus/catapult-server`); no use of Symbol/NEM
      logos; no implication of official endorsement. (Notice present in THIRD_PARTY_NOTICES.)

## 5. Provenance (recommended, not strictly required)

- [ ] Base image pinned by digest in `Dockerfile.selfcontained`.
- [ ] SBOM generated and attached (the publish workflow emits one).
- [ ] Image signed (cosign keyless via the publish workflow).

## 6. Green path (automated) and the one-time setup

**Green path — no manual step.** Pushing a `catapult-image-v*` tag runs the publish
workflow, which: runs the license-scope gate, builds the image (the gate runs again
inside the Dockerfile), publishes it to GHCR with SBOM + provenance, and records the
evidence (revision, digest, gate result) to the run summary. If the gate is green, that
is the complete, recorded compliance evidence — nothing to sign by hand.

**One-time setup (first publish only).** GHCR creates a *private* package on the first
push. Flip it to public once (package settings → Change visibility → Public; optionally
link it to this repo). Every later release then stays public automatically. The workflow
also attempts this via the API best-effort.

**Exception path — the gate failed.** If `check-license-scope.sh` reports findings
(e.g. an upstream sync introduced a Tech Bureau Commercial-licensed file), the build and
publish are blocked automatically. Resolving it is a human decision: review the findings,
and either exclude the offending files from the build or stop publishing that revision.
Record that decision with the template in Section 7. The green path never needs it.

## 7. Exception sign-off record (template — only when the gate flags something)

> Use this ONLY when Section 1's gate failed and a human decided how to proceed. The
> normal green path is evidenced automatically (Section 6) and needs no manual record.
> Copy this block into the release PR / issue and fill in every `<...>`.

```markdown
## catapult-server image — publishing sign-off

- Image tag(s):     <e.g. ghcr.io/nemtus/catapult-server:v1.0.0>
- Image digest:     <sha256:... from `docker buildx imagetools inspect` after push>
- Source revision:  <full git commit on github.com/nemtus/symbol — matches image.revision label>
- Base image:       <ubuntu:24.04@sha256:... pinned digest>
- Date:             <YYYY-MM-DD>

### Evidence (attach command output)
- [ ] `bash client/catapult/scripts/check-license-scope.sh` PASSED on THIS revision
      → output: <paste the RESULT line + any findings>
- [ ] `resources/` reviewed — no non-LGPL / commercial payload: <notes>
- [ ] Source revision is public on github.com/nemtus/symbol: <link to commit>
- [ ] Image bundles licenses: `/opt/catapult/licenses/{LGPL-3.0.txt,LICENSE.txt,THIRD_PARTY_NOTICES.md}`
      `docker run --rm --entrypoint ls <image> /opt/catapult/licenses` → <paste>
- [ ] Runtime image free of test-only deps (gtest/benchmark): <notes>
- [ ] THIRD_PARTY_NOTICES.md complete & RocksDB Apache-2.0 elected: <confirmed>

### Legal review
- Reviewer:         <name / "legal counsel" / "N/A — rationale">
- Outcome:          <approved | changes required>
- Notes:            <...>

### Decision
- [ ] APPROVED to publish (make GHCR package public)
- Approver (name):  <name>
- Role / authority: <e.g. NEMTUS maintainer authorised to accept this risk>
- Date:             <YYYY-MM-DD>
- Signature:        <name / git handle>
```

After this record is completed and approved, change the GHCR package visibility to public
manually (Package settings → Danger Zone → Change visibility). The CI workflow never does
this automatically.

## References
- `client/catapult/LICENSE.txt`, `client/catapult/COPYING.LESSER`
- `client/catapult/THIRD_PARTY_NOTICES.md`
- `client/catapult/Dockerfile.selfcontained`, `.github/workflows/catapult-image.yml`
