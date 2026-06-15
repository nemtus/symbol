# RELEASE — Release / Tag Conventions

This repository is a rename-republish mirror of upstream `symbol/symbol`, and the
monorepo hosts multiple artifacts side by side. This document defines the
conventions for **manually creating tags and GitHub Releases**.

## Published artifacts

| Path | Package name | License | Published to |
| --- | --- | --- | --- |
| `sdk/javascript` | `@nemtus/symbol-sdk` | MIT | npm |
| `openapi` | `@nemtus/symbol-openapi` | Apache-2.0 | npm |
| `client/rest` | `symbol-api-rest` | LGPL family | **Not published** (no tag) |

## Principles

- **Each artifact is versioned independently with semver.** A bump in the SDK
  does not require bumping openapi. The `version` field in each `package.json`
  is the source of truth for that package.
- **Tags do NOT trigger npm publishing.** Publishing is driven by the following
  workflows, which compare the `version` in the relevant `package.json` against
  what is already on npm whenever `dev` is pushed (*version-diff driven*):
  - `.github/workflows/publish.yml` — `@nemtus/symbol-sdk`
  - `.github/workflows/openapi-publish.yml` — `@nemtus/symbol-openapi`

  Both publish through the `npm-production` environment, which requires reviewer
  approval.
- Therefore **tags / Releases are not the publish trigger; they are record-keeping
  markers** that pin "which commit corresponds to which version of which artifact."

## Tag naming convention

Use the **published npm coordinate** as the tag name:

```text
@nemtus/<package>@<version>
```

Examples:

```text
@nemtus/symbol-sdk@3.3.2       → @nemtus/symbol-sdk@3.3.2 on npm
@nemtus/symbol-openapi@1.0.6   → @nemtus/symbol-openapi@1.0.6 on npm
```

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
  `origin`.
- Do not tag the non-published `client/rest`.

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
