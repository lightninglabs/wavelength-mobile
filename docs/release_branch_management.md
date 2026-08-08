# Release Branch Management

## Overview

This document describes the branch management workflow for damobile releases.
The `main` branch remains open for merges at all times. Release stabilization
happens on dedicated release branches, with CI automation handling backports of
labeled changes. The app version lives in the native Android and iOS build
configuration.

## Branch Model Principles

**Main is always open.** Developers merge approved pull requests at any time,
with no coordination around release windows and no merge freezes.

**Each major release gets a dedicated branch.** When cutting a new major
version, we branch from `main` as `v0.1.x-branch`. That branch carries every
patch release for the version series.

**CI automation handles backports.** Pull requests merged to `main` and labeled
`backport-v*` are automatically backported to the matching release branch. See
[backport-workflow.md](backport-workflow.md).

**Changes flow one direction only.** Changes move from `main` to release
branches, never in reverse.

## Version Sources

The app version is set in two native files, which are the source of truth:

- **Android:** `android/app/build.gradle.kts` — `versionName` (the user-facing
  version, e.g. `"0.1.0"`) and `versionCode` (a monotonically increasing
  integer bumped on every release).
- **iOS:** `ios/Sample/project.yml` — `MARKETING_VERSION` (e.g. `"0.1.0"`) and
  `CURRENT_PROJECT_VERSION` (the build number). `project.yml` is the XcodeGen
  spec; the generated `.xcodeproj` is a build artifact and must not be edited by
  hand.

Keep `versionName` and `MARKETING_VERSION` in sync across platforms for a given
release.

## Major Release Process

When ready to begin a major release (for example, the `0.1` series):

1. Create a release branch from `main`: `git checkout -b v0.1.x-branch main`
2. Push the branch: `git push origin v0.1.x-branch`
3. On the release branch, set the release version (`0.1.0`) via a pull request
   against `v0.1.x-branch`: `versionName`/`MARKETING_VERSION` to `0.1.0`, and
   bump `versionCode`/`CURRENT_PROJECT_VERSION`.
4. Configure branch protection for `v0.1.x-branch` on GitHub.
5. Create the `backport-v0.1.x-branch` label so backport automation can route
   fixes to the branch.

### Tagging the Release

After the version PR merges onto the release branch, tag the merge commit with
the release tagging helper:

```bash
./scripts/tag-release.sh v0.1.0 --branch v0.1.x-branch
git push <upstream-remote> v0.1.0
```

The helper verifies that HEAD is in sync with the upstream release branch and
that both the Android `versionName` and the iOS `MARKETING_VERSION` match the
requested tag before creating the signed tag.

## Minor Release Process

Patch releases reuse the existing release branch. When a fix is needed for
`0.1.0`:

1. Develop and merge the fix to `main`.
2. Add the `backport-v0.1.x-branch` label so CI backports it.
3. On the release branch, bump `versionName`/`MARKETING_VERSION` to `0.1.1`
   (and `versionCode`/`CURRENT_PROJECT_VERSION`) via a pull request against
   `v0.1.x-branch`.
4. After the PR merges, tag the merge commit:
   `./scripts/tag-release.sh v0.1.1 --branch v0.1.x-branch` and push the tag.

Multiple patch releases (0.1.1, 0.1.2, …) live on the same `v0.1.x-branch`.

## Manual Cherry-Picking

When a fix applies only to a release branch and not to `main`, cherry-pick it
directly and open a PR into the target release branch:

```bash
git checkout v0.1.x-branch
git cherry-pick <commit-hash>
git cherry-pick --continue   # if conflicts
```

Document why the normal backport flow was bypassed, and make sure any change
that should also exist on `main` lands there too.
