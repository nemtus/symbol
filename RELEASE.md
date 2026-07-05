# RELEASE — Release / Tag Conventions

This repository is a rename-republish mirror of upstream `symbol/symbol`, and the
monorepo hosts multiple artifacts side by side. This document defines the
conventions for **manually creating tags and GitHub Releases**.

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

  **Tagging differs by ecosystem.** The npm workflows do NOT tag (see the manual
  procedure below). The **PyPI workflows tag automatically**: after a successful
  publish, a separate `tag` job creates `nemtus-symbol-sdk@<version>` /
  `nemtus-catparser@<version>` and a matching GitHub Release. That job is the only
  place `contents: write` is granted, and it runs **no build and no third-party
  code** (just the `gh` CLI), so the `contents: read` build/publish job is never
  exposed to a write token. The job is idempotent (skips if the release exists).
- Therefore **tags / Releases are not the publish trigger; they are record-keeping
  markers** that pin "which commit corresponds to which version of which artifact."

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

`mirror-sync.yml`'s `upstream-tags` job mirrors every upstream `symbol/symbol` tag
into this fork's `refs/upstream/tags/*` namespace (append-only: no force, no
prune). Archived refs deliberately do NOT appear in `git tag` or the Releases UI —
the visible tag namespace stays 100% NEMTUS release coordinates — but every
upstream release point and its objects are preserved on the fork for disaster
recovery / hard-fork readiness.

- List them: `git ls-remote origin 'refs/upstream/tags/*'`
- Local clones with the standard fetch-only `upstream` remote already carry the
  same tags as `refs/remotes/upstream/tags/*`, fetched directly from upstream.
- A rejected (non-fast-forward) push in that job means upstream **moved** a tag.
  The failing run is the tamper alarm working as designed — investigate upstream
  intent before resolving.
- Hard-fork promotion: create a NEMTUS-named tag/branch pointing at the archived
  ref (e.g. `git tag catapult-fork-base <sha>`); never republish bare upstream
  tag names.

## Procedure

Create the tag / Release **after npm publishing has completed.**

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

## Future automation (reference)

Today the flow is "publish via version-diff → tag manually." To avoid missing
tags, a step that automatically creates the tag + Release could be added after
the successful publish step in each workflow (this would require granting
`permissions: contents: write` and revisiting the auth setup used for the push).
For now, the manual procedure in this document is the rule.
