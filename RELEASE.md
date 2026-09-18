# RELEASE — Release / Tag Conventions

This repository is a rename-republish mirror of upstream `symbol/symbol`, and the
monorepo hosts multiple artifacts side by side. This document defines the tag /
GitHub Release conventions. Tags and Releases are created **automatically by the
publish workflows**; the manual procedure below remains as a recovery fallback.

## Published artifacts

| Path | Package name | License | Published to |
| --- | --- | --- | --- |
| `sdk/javascript` | `@nemtus/symbol-sdk` | MIT | npm |
| `openapi` | `@nemtus/symbol-openapi` | Apache-2.0 | npm |
| `sdk/python` | `nemtus-symbol-sdk` (import module `symbolchain`) | MIT | PyPI |
| `catbuffer/parser` | `nemtus-catparser` (import module `catparser`) | MIT | PyPI |
| `client/rest` | `symbol-api-rest` | LGPL family | **Not published** (no tag) |

> PyPI has no scopes, so the distribution names are flat. Upstream is
> `symbol-sdk-python` / `catparser`; nemtus republishes them as `nemtus-symbol-sdk`
> / `nemtus-catparser`. Only the **distribution** name changes — the import module
> name (`symbolchain` / `catparser`) is unchanged. The SDK drops the redundant
> `-python` suffix so it reads alongside `@nemtus/symbol-sdk` on npm; the two are
> different artifacts on different registries (PyPI/Python vs npm/JavaScript).

## Principles

- **Each artifact is versioned independently with semver.** A bump in the SDK
  does not require bumping openapi. The `version` field in each package manifest
  is the source of truth for that package — `package.json` for the npm packages
  (`sdk/javascript`, `openapi`), `pyproject.toml` for the PyPI packages
  (`sdk/python`, `catbuffer/parser`).
- **Tags do NOT trigger publishing.** Publishing is driven by the following
  workflows, which compare the `version` in the relevant manifest against what is
  already on the registry (npm or PyPI) whenever `dev` is pushed (*version-diff
  driven*):
  - `.github/workflows/publish.yml` — `@nemtus/symbol-sdk`
  - `.github/workflows/openapi-publish.yml` — `@nemtus/symbol-openapi`
  - `.github/workflows/pypi-sdk-publish.yml` — `nemtus-symbol-sdk` (PyPI)
  - `.github/workflows/pypi-catparser-publish.yml` — `nemtus-catparser` (PyPI)

  The npm workflows publish through the `npm-production` environment; the PyPI
  workflows publish through `pypi-production`. Both environments require reviewer
  approval. npm uses npm Trusted Publishing (OIDC); PyPI uses PyPI Trusted
  Publishing (OIDC). Neither uses a long-lived token.

  > First-time PyPI setup (one-off, manual): register each package as a PyPI
  > **pending publisher** (repository `nemtus/symbol`, the workflow filename above,
  > environment `pypi-production`) before the first run, and create the
  > `pypi-production` GitHub environment with required reviewers.

  **All four publish paths tag automatically.** After a successful publish, a
  separate `tag` job creates the package-coordinate tag
  (`@nemtus/symbol-sdk@<version>`, `@nemtus/symbol-openapi@<version>`,
  `nemtus-symbol-sdk@<version>`, `nemtus-catparser@<version>`) and a matching
  GitHub Release. That job is the only place `contents: write` is granted, and it
  runs **no build and no third-party code** (just the `gh` CLI), so the
  `contents: read` build/publish job is never exposed to a write token. The job
  is idempotent (skips if the release exists).
- Therefore **tags / Releases are not the publish trigger; they are record-keeping
  markers** that pin "which commit corresponds to which version of which artifact."
- **A republished version ships the UPSTREAM tree tagged with that version, not the
  dev tree.** See "Publishing from the upstream release tag" below.

## Publishing from the upstream release tag

The publish workflows are triggered by a push to `dev` and check out
`${{ github.sha }}` — the merged dev commit. `dev` is a running merge of
`upstream/dev`, so whenever a mirror-sync PR sits unmerged for a while, that tree is
already **past** the upstream tag that introduced the version bump. Publishing
straight from it would ship a version number whose content upstream never released
under that number, breaking the mirror's only contract: *same content, different
package name*.

`.github/scripts/pin-upstream-tag.sh` closes that gap. In the `publish` job, before
`apply-nemtus-patch.sh` runs, it replaces the package directory with the upstream
tree at `<pkg_dir>/v<version>` (e.g. `sdk/javascript/v3.3.3`) — so the rename layer
is re-applied on top of exactly the tree upstream released. The `check` job runs the
same resolution with `--verify-only`, so an unpinnable version fails **before** the
`npm-production` / `pypi-production` approval prompt is raised, and the `tag` job
records the upstream tag in the GitHub Release notes.

It never pins a tree it could not verify. A missing tag, an unreadable manifest at
the tag, and a manifest declaring a different version all take the same path; only
`PIN_MODE` decides what that path does:

| Package | `PIN_MODE` | Why |
| --- | --- | --- |
| `sdk/javascript` | `strict` | Upstream tags `sdk/javascript/v*` at the bump commit; real dependents install this. Unverifiable tag → **publish fails.** |
| `sdk/python` | `strict` | Same, for `sdk/python/v*`. |
| `openapi` | `warn` | Upstream's tagging cannot support pinning (below). Unverifiable tag → publishes the dev tree, with the divergence in the run summary and release notes. |
| `catbuffer/parser` | `warn` | Same. |

The two `warn` packages are not an oversight — upstream's tags for them are
unusable as release markers:

- `openapi` 1.0.5 and `catparser` 3.2.0 were released with **no upstream tag at
  all** (both were published from dev HEAD for exactly that reason);
- `openapi/v1.0.4` points at a commit whose `openapi/package.json` already says
  **1.0.5** — the tag was pushed after the next bump;
- `catbuffer/parser/v3.1.0` predates `catbuffer/parser/pyproject.toml`, so there is
  no manifest at the tag to verify against.

`strict` on those would freeze both packages permanently. If upstream's tagging for
them ever becomes reliable, flip `PIN_MODE` to `strict` in the two workflows —
nothing else needs to change.

Two consequences worth knowing:

- **`sdk/javascript` re-locks after the pin.** The pin restores upstream's
  lockfile, which resolves the real `symbol-crypto-wasm-node`, while the rename
  layer repoints `package.json` at the `@nemtus` alias. `relock-sdk.sh` runs right
  after to reconcile them, or `npm ci` would fail (or silently install upstream's
  package).
- **A nemtus `.postN` version still pins.** The suffix is a nemtus-only repackage of
  the same upstream source, so it is stripped for the tag lookup
  (`3.3.2.post1` → `sdk/python/v3.3.2`) and restored in the manifest afterwards.

When a `strict` publish fails because upstream has not tagged yet, nothing is
broken — the merge to `dev` stands, and the package simply is not published. Once
upstream pushes the tag, re-run the workflow via `workflow_dispatch`.

## Tag naming convention

Use the **published package coordinate** as the tag name — the npm package name
for npm artifacts, the PyPI distribution name for PyPI artifacts:

```text
@nemtus/<package>@<version>   # npm artifacts
<dist-name>@<version>         # PyPI artifacts
```

Examples:

```text
@nemtus/symbol-sdk@3.3.2       → @nemtus/symbol-sdk@3.3.2 on npm
@nemtus/symbol-openapi@1.0.6   → @nemtus/symbol-openapi@1.0.6 on npm
nemtus-symbol-sdk@3.3.2        → nemtus-symbol-sdk 3.3.2 on PyPI
nemtus-catparser@3.2.0         → nemtus-catparser 3.2.0 on PyPI
```

(PyPI distribution names have no `@scope`, so the tag is just
`<dist-name>@<version>`. It still lives in a namespace upstream never uses, so it
cannot collide with upstream's `sdk/python/v*` / `catbuffer/parser/v*` tags.)

- **Do NOT use a `<package path>/v<semver>` scheme** (e.g. `sdk/javascript/v3.3.2`,
  `openapi/v1.0.6`). This repository is a mirror, so it inherits upstream
  `symbol/symbol`'s own tag namespace, which already uses `sdk/javascript/v*`,
  `openapi/v*`, etc. Because nemtus republishes the **same upstream version
  numbers**, a path-based tag collides with the upstream tag (e.g.
  `sdk/javascript/v3.3.1` already exists and points to an upstream commit).
- The `@nemtus/<package>@<version>` form matches the artifact's npm identity
  exactly and lives in a namespace upstream never uses, so it cannot collide.
  It also matches the de-facto monorepo convention (changesets / Lerna).
- The tag name contains `@` and `/`, so **quote it in the shell** (e.g.
  `git tag '@nemtus/symbol-sdk@3.3.2'`).
- Bare `v3.0.x` tags and any `sdk/*` / `openapi/*` tags are legacy / upstream
  tags. Do not add new ones, and do not push the inherited upstream tags to
  `origin` as tags. (Upstream tags ARE preserved on the fork automatically —
  outside the tag namespace; see "Upstream tag archive" below.)
- Do not tag the non-published `client/rest`.

## Upstream tag archive

Every upstream `symbol/symbol` tag is mirrored into this fork's
`refs/upstream/tags/*` namespace (append-only). Archived refs deliberately do NOT
appear in `git tag` or the Releases UI — the visible tag namespace stays 100%
NEMTUS release coordinates — but every upstream release point and its objects are
preserved on the fork for disaster recovery / hard-fork readiness.

Division of labor (GitHub constraint: GITHUB_TOKEN cannot create refs whose trees
contain workflow files — a `workflows` permission it can never be granted — and
most upstream tags contain upstream's `.github/workflows/*`):

- **Archiving (push)** happens from the **maintainer lane**, whose fine-grained
  PAT carries Workflows RW: `nemtus-ops sync-local` pushes
  `refs/remotes/upstream/tags/* -> refs/upstream/tags/*` (no force — a rejected
  push means the archived value differs; investigate before overriding).
- **Verification (tamper alarm)** is `mirror-sync.yml`'s `upstream-tags` job:
  a credential-free ls-remote comparison of upstream vs the archive on every
  scheduled run. A **moved** tag (archived value != upstream value) fails the run
  and pages Discord — investigate upstream intent before re-archiving. New
  not-yet-archived tags are reported in the run summary (not a failure).

Reference:

- List the archive: `git ls-remote origin 'refs/upstream/tags/*'`
- Local clones with the standard fetch-only `upstream` remote already carry the
  same tags as `refs/remotes/upstream/tags/*`, fetched directly from upstream.
- Hard-fork promotion: create a NEMTUS-named tag/branch pointing at the archived
  ref (e.g. `git tag catapult-fork-base <sha>`); never republish bare upstream
  tag names.

## Manual procedure (fallback)

Normally unnecessary — the `tag` jobs create the tag + Release automatically after
every successful publish. Use this only for recovery (e.g. a deleted tag, or a
publish that predates the automation). Create the tag / Release **after npm
publishing has completed.**

1. A mirror-sync PR is merged into `dev`.
2. `publish.yml` / `openapi-publish.yml` completes the npm publish
   (including the `npm-production` approval).
3. Once you have confirmed the publish succeeded, create the tag and Release.
   Tag the commit the artifact was actually built from — for a CI publish this is
   the `dev` commit that carried the published `package.json`; for a manual
   `npm publish` it is recorded as the package's `gitHead` on npm
   (`npm view @nemtus/symbol-sdk@<version> gitHead`).

```bash
# Example: after publishing @nemtus/symbol-sdk at 3.3.2
git checkout dev && git pull
git tag '@nemtus/symbol-sdk@3.3.2'
git push origin '@nemtus/symbol-sdk@3.3.2'

gh release create '@nemtus/symbol-sdk@3.3.2' --repo nemtus/symbol \
  --title '@nemtus/symbol-sdk v3.3.2' \
  --notes 'Mirror of upstream symbol/symbol. Published @nemtus/symbol-sdk@3.3.2.'
```

```bash
# Example: after publishing @nemtus/symbol-openapi at 1.0.6
git checkout dev && git pull
git tag '@nemtus/symbol-openapi@1.0.6'
git push origin '@nemtus/symbol-openapi@1.0.6'

gh release create '@nemtus/symbol-openapi@1.0.6' --repo nemtus/symbol \
  --title '@nemtus/symbol-openapi v1.0.6' \
  --notes 'Mirror of upstream symbol/symbol. Published @nemtus/symbol-openapi@1.0.6.'
```

## Checklist / notes

- [ ] Tag the commit the artifact was built from: the `dev` commit carrying the
      published `package.json` for a CI publish, or the npm `gitHead` for a manual
      `npm publish` (`npm view @nemtus/<package>@<version> gitHead`).
- [ ] Always follow the order **npm publish → tag / Release**. Reversing it leaves
      a tag that predates the publish.
- [ ] Include the package name in the Release title (e.g. `@nemtus/symbol-sdk
      v3.3.2`) to keep the Releases list readable.
- [ ] If you need to re-tag the same version, delete the existing tag first
      (`git push origin ':@nemtus/symbol-sdk@3.3.2'` removes it on the remote).
- [ ] **Always pass `--repo nemtus/symbol` to `gh`** (e.g. `gh pr create`,
      `gh release create`). This clone also has the upstream `symbol/symbol`
      remote, so `gh` resolves the default repo to `symbol/symbol` and would
      otherwise target the wrong repository.

## Automation status

Implemented: all four publish workflows (npm and PyPI) auto-create the tag +
Release via an isolated `tag` job — `contents: write` is granted only there, and
the job runs no build, no third-party code, and no checkout. The manual procedure
above remains as a recovery fallback.
