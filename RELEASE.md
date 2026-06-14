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

```text
<package path>/v<semver>
```

Examples:

```text
sdk/javascript/v3.3.2     → @nemtus/symbol-sdk@3.3.2
openapi/v1.0.6            → @nemtus/symbol-openapi@1.0.6
```

- The path prefix makes it unambiguous which artifact a tag belongs to.
- Stay consistent with the existing `sdk/javascript/v*` / `sdk/python/v*` scheme.
- Bare `v3.0.x` tags are legacy tags inherited from upstream. Do not add new ones.
- Do not tag the non-published `client/rest`.

## Procedure

Create the tag / Release **after npm publishing has completed.**

1. A mirror-sync PR is merged into `dev`.
2. `publish.yml` / `openapi-publish.yml` completes the npm publish
   (including the `npm-production` approval).
3. Once you have confirmed the publish succeeded, create the tag and Release on
   the artifact's path.

```bash
# Example: after publishing @nemtus/symbol-sdk at 3.3.2
git checkout dev && git pull
git tag sdk/javascript/v3.3.2
git push origin sdk/javascript/v3.3.2

gh release create sdk/javascript/v3.3.2 \
  --title "@nemtus/symbol-sdk v3.3.2" \
  --notes "Mirror of upstream symbol/symbol. Published @nemtus/symbol-sdk@3.3.2."
```

```bash
# Example: after publishing @nemtus/symbol-openapi at 1.0.6
git checkout dev && git pull
git tag openapi/v1.0.6
git push origin openapi/v1.0.6

gh release create openapi/v1.0.6 \
  --title "@nemtus/symbol-openapi v1.0.6" \
  --notes "Mirror of upstream symbol/symbol. Published @nemtus/symbol-openapi@1.0.6."
```

## Checklist / notes

- [ ] Tag the **`dev` commit that contains the published `package.json`** (its
      `version`).
- [ ] Always follow the order **npm publish → tag / Release**. Reversing it leaves
      a tag that predates the publish.
- [ ] Include the package name in the Release title (e.g. `@nemtus/symbol-sdk
      v3.3.2`) to keep the Releases list readable.
- [ ] If you need to re-tag the same version, delete the existing tag first
      (`git push origin :sdk/javascript/v3.3.2` removes it on the remote).

## Future automation (reference)

Today the flow is "publish via version-diff → tag manually." To avoid missing
tags, a step that automatically creates the tag + Release could be added after
the successful publish step in each workflow (this would require granting
`permissions: contents: write` and revisiting the auth setup used for the push).
For now, the manual procedure in this document is the rule.
