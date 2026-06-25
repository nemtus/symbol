# Publishing-compliance — symbol-rest image

symbol-rest is **published as a public container image** (`ghcr.io/nemtus/symbol-rest`)
from `client/rest/Dockerfile.nemtus`. Compliance is enforced and evidenced
**automatically** by CI/CD — while the gate is green there is **no per-release manual
step**. It is engineering guidance, **not legal advice**; because a third party
(Tech Bureau, Corp.) holds copyright and the source is dual-licensed, the automated
`check-license-scope.sh` gate (Section 1) is the agreed, recorded standard that no
commercial-licensed code is shipped.

**How it is automated (no manual work on the green path):**
1. `check-license-scope.sh` runs as a CI step **and** inside the Dockerfile, hard-blocking
   any build/publish if a commercial-licensed file appears (Section 1).
2. The PASS report is bundled in the image at `/app/licenses/LICENSE-SCOPE-REPORT.txt`,
   and an SBOM + SLSA provenance attestation is attached to the published image.
3. `.github/workflows/rest-image.yml` records revision + image digest + gate result to
   the workflow run summary on every publish.

A human is needed **only** in the exception case where the gate fails — then publishing
is blocked and Section 6/7 apply.

## 1. The licensing gate (the only blocker)

`client/rest/LICENSE.txt` states each source file is **LGPL-3.0** *unless its header or a
directory `LICENSE` declares the **Tech Bureau Commercial License***. Publishing is only
permissible if the shipped source contains **no commercial-licensed file**.

Verify with the single source-of-truth scanner (also run by
`.github/workflows/rest-image.yml`, where it hard-blocks publishing on failure):

```sh
bash client/rest/scripts/check-license-scope.sh
```

It checks three things and exits non-zero on any finding: (1) no directory-level LICENSE
other than the root `COPYING.LESSER`/`LICENSE.txt` (node_modules excluded); (2) no
`src/**/*.js` contains `tech bureau commercial`/`commercial license`/`proprietary`/
`confidential`; (3) every `src/**/*.js` carries the LGPL header, except the allowlisted
generated Rosetta client (`src/plugins/rosetta/openApi/**`, Apache-2.0) and
`src/plugins/metadata/metal.js` (headerless rest code). As of the last check this tree is
**all LGPL-3.0** (0 commercial-licensed files). Re-run on the exact revision being
published — the dual-license clause means commercial files *could* appear after a sync.

- [ ] `check-license-scope.sh` re-run on the exact revision being published; output recorded.
- [ ] `resources/` reviewed (config templates; data, not commercial-licensed code).

## 2. LGPL-3.0 obligations (mechanical — already wired into the image)

- [x] LGPL text shipped in image at `/app/COPYING.LESSER` (and `/app/LICENSE.txt`).
- [x] `THIRD_PARTY_NOTICES.md` shipped at `/app/` and the gate report at `/app/licenses/`.
- [x] Corresponding-source pointer: `org.opencontainers.image.source` +
      `org.opencontainers.image.revision` labels point at the public nemtus commit.
- [ ] Confirm the published revision is actually pushed/public on `github.com/nemtus/symbol`.
- [ ] Any nemtus modifications to rest source are disclosed under LGPL in that fork.
- Relinking clause: satisfied — rest is shipped as its own LGPL work (interpreted by an
  unmodified Node.js runtime) with public source; no proprietary combination.

## 3. Bundled-dependency notices

- [x] `THIRD_PARTY_NOTICES.md` covers rest (LGPL-3.0), the generated Rosetta client
      (Apache-2.0), the npm production tree, and the Ubuntu/Node base.
- [x] npm production dependencies bundle each package's own `LICENSE` under
      `/app/node_modules/<pkg>/`; the published image also carries an SBOM attestation.

## 4. Trademark

- [ ] Image named neutrally (`ghcr.io/nemtus/symbol-rest`); no use of Symbol/NEM logos;
      no implication of official endorsement. (Notice present in THIRD_PARTY_NOTICES.)

## 5. Provenance (recommended, not strictly required)

- [ ] Base image pinned by digest in `Dockerfile.nemtus`.
- [ ] SBOM generated and attached (the publish workflow emits one).
- [ ] Image signed (cosign keyless) — left as a follow-up to avoid an unpinned action.

## 6. Green path (automated) and the one-time setup

**Green path — no manual step.** Pushing a `rest-image-v*` tag runs the publish workflow,
which: runs the license-scope gate, builds the image (the gate runs again inside the
Dockerfile), publishes it to GHCR with SBOM + provenance, and records the evidence
(revision, digest, gate result) to the run summary. If the gate is green, that is the
complete, recorded compliance evidence — nothing to sign by hand.

**One-time setup (first publish only).** GHCR creates a *private* package on the first
push. Flip it to public once (package settings → Change visibility → Public; optionally
link it to this repo). Note: the **organization** must also allow public packages
(Org settings → Packages), otherwise the package-level control is disabled. Every later
release then stays public automatically. The workflow does NOT change visibility itself.

**Exception path — the gate failed.** If `check-license-scope.sh` reports findings (e.g.
an upstream sync introduced a Tech Bureau Commercial-licensed file), the build and publish
are blocked automatically. Resolving it is a human decision: review the findings, and
either exclude the offending files from the build or stop publishing that revision.
Record that decision with the template in Section 7. The green path never needs it.

## 7. Exception sign-off record (template — only when the gate flags something)

> Use this ONLY when Section 1's gate failed and a human decided how to proceed. The
> normal green path is evidenced automatically (Section 6) and needs no manual record.
> Copy this block into the release PR / issue and fill in every `<...>`.

```markdown
## symbol-rest image — publishing sign-off

- Image tag(s):     <e.g. ghcr.io/nemtus/symbol-rest:v2.5.1>
- Image digest:     <sha256:... from `docker buildx imagetools inspect` after push>
- Source revision:  <full git commit on github.com/nemtus/symbol — matches image.revision label>
- Base image:       <ubuntu:24.04@sha256:... pinned digest>
- Date:             <YYYY-MM-DD>

### Evidence (attach command output)
- [ ] `bash client/rest/scripts/check-license-scope.sh` PASSED on THIS revision
      → output: <paste the RESULT line + any findings>
- [ ] `resources/` reviewed — no non-LGPL / commercial payload: <notes>
- [ ] Source revision is public on github.com/nemtus/symbol: <link to commit>
- [ ] Image bundles licenses: `/app/{COPYING.LESSER,LICENSE.txt,THIRD_PARTY_NOTICES.md}`
      and `/app/licenses/LICENSE-SCOPE-REPORT.txt`
      `docker run --rm --entrypoint ls <image> /app/licenses` → <paste>
- [ ] THIRD_PARTY_NOTICES.md complete (rest + Rosetta + npm tree + base): <confirmed>

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
- `client/rest/LICENSE.txt`, `client/rest/COPYING.LESSER`
- `client/rest/THIRD_PARTY_NOTICES.md`
- `client/rest/Dockerfile.nemtus`, `.github/workflows/rest-image.yml`
