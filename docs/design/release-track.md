# Design: automated *release* builds tracking Verilator releases

Status: **implemented** (see §7 for where the implementation differs)
Date: 2026-08-24
Scope: `verilator-bin` CI + the shared `edapack-common` build pipeline

## 1. Goal

Today every build we publish is a pre-release of top-of-trunk, and a human has
to manually promote one of them to `latest`. We want a second, automatic track:

* When Verilator publishes a new release **newer than the last release we
  built**, CI builds it automatically.
* A release build is built **from that upstream tag**, not from `master`.
* Its version is **simple** — `5.050`, tag `v5.050` — with no build-ID suffix.
* It is published as a **full release** (not pre-release) and it **moves
  `latest`**.
* The release body carries the **upstream Verilator release notes** for that
  version, so our release page is self-describing.
* The existing weekly top-of-trunk pre-release track keeps working — with one
  change: it stands down in a week where the release track builds (§4.6).

## 2. What we have today

### 2.1 Two generations of the pipeline are in flight

| | On `origin/main` (live) | On local `main` (5 unpushed commits) |
|---|---|---|
| Workflow | bespoke `.github/workflows/ci.yml` (~300 lines) | thin caller → `edapack/edapack-common/.github/workflows/build-release.yml@v1` |
| Version | `<X.YYY>.<github.run_id>` where `X.YYY` is scraped from `configure.ac` on `master` | `<core_version>.<UTC date>` |
| Matrix | 3× manylinux x86_64, 2× manylinux aarch64, macOS arm64 | same set, via the `targets` matrix input |
| Change gate | none (builds every Sunday) | manifest-digest diff vs. last release |

The last eight CI runs (through 2026-08-23, run `32639969514`) all executed the
**legacy** jobs (`version-check` / `build-linux-x86_64` / `publish`), confirming
the edapack-common migration is staged but not yet pushed.

### 2.2 Current release inventory

```
v5.051.32639969514  Pre-release  2026-08-23
v5.051.31947570909  Pre-release  2026-08-16
...
v5.049.27094495137  Latest       2026-06-07   <-- hand-promoted
```

So `latest` is a *top-of-trunk snapshot from June* that a human marked as
stable. That is exactly what this design replaces.

### 2.3 The shared pipeline (`edapack-common`)

* `build-inputs.yaml` declares a `core` input plus `dependencies`, each with a
  `policy` (`branch:X`, `tag:X`, `latest-tag`, `latest-release`).
* `resolve-inputs.py` resolves every policy to a concrete SHA and computes an
  `inputs_digest` over tracked SHAs + the recipe SHA.
* `manifest-diff.py` is the change gate: build if no prior manifest / `--force`
  / push / pinned dispatch / digest changed.
* `build-release.yml` = `resolve` → `build` (matrix) → `publish`
  (`gh release create ... [--prerelease]`).
* `manifest.json` ships as a release asset and is the state carried between runs.

## 3. Problems found while reviewing (must be fixed alongside this feature)

These are pre-existing defects in the staged pipeline. The release track depends
on the same machinery, so they are in scope.

**P1 — `ci.yml` passes an input `@v1` does not accept.**
`.github/workflows/ci.yml` passes `targets:`. The `v1` tag of edapack-common
(commit `1e0d04a`) only accepts `images:`; `targets` exists on `main` but was
never re-tagged. Pushing local `main` as-is fails the workflow immediately.
*Fix: move the `v1` tag to current edapack-common `main` (or pin to a SHA).*

**P2 — a `branch:` core policy yields no version.**
`_derive_version()` returns `None` for `branch:master`, and the version step
does `i["version"] or "0"`, so the new pipeline would publish `0.20260824`
instead of `5.051.<id>`. The legacy workflow avoided this by scraping
`AC_INIT` out of `configure.ac`. That capability must be reintroduced.

**P3 — the change gate reads the wrong "previous".**
`gh release download` with no tag pulls from GitHub's *latest* release, which
by definition excludes pre-releases. So the dev track would diff against the
hand-promoted June release, not against last week's build. Once real releases
exist this gets worse, not better: each track needs *its own* previous manifest.

**P4 — legacy releases carry no `manifest.json`.**
Until the first new-pipeline release lands, the gate always sees
`previous=none` → `build_needed=true` → it builds every time. Self-correcting,
but worth knowing during rollout.

**P5 — Verilator publishes **tags only**, not GitHub Releases.**
`gh api repos/verilator/verilator/releases` returns `[]`; there are 338 tags,
all matching `^v\d+\.\d+$` (newest `v5.050`). Therefore the release track must
use the **`latest-tag`** policy, not `latest-release` — `latest-release` would
404. `_version_sort_key` orders these tags correctly (verified over all 338).

## 4. Proposed design

### 4.1 Two tracks, one reusable workflow

Introduce a first-class notion of a **track** in `edapack-common`:

| | `dev` track (existing) | `release` track (new) |
|---|---|---|
| Core ref | `branch:master` | `latest-tag` (newest upstream tag) |
| Version | `<probe>.<build-id>` e.g. `5.051.32639969514` | `<tag version>` e.g. `5.050` |
| Our tag | `v5.051.32639969514` | `v5.050` |
| Pre-release | yes | **no** |
| Moves `latest` | never (`--latest=false`) | **yes** (`--latest`) |
| Gate | inputs digest changed vs. last *dev* release | our tag `v<ver>` does not already exist |
| Trigger | weekly cron, push, dispatch | weekly cron, dispatch |
| Precedence | stands down when a new upstream tag exists | always wins |

Both tracks run the identical `build` and `publish` jobs; only `resolve`
differs. Everything downstream (`build.sh`, CMake, tarball naming, manifest)
is unchanged — it already keys off `EC_VERSION` / `EC_TAG`.

### 4.2 `build-inputs.yaml` changes

```yaml
schema: edapack.build-inputs/1

core:
  name: verilator
  repo: https://github.com/verilator/verilator
  policy: branch:master          # dev track
  release_policy: 'latest-tag:^v\d+\.\d+$'   # release track (NOT latest-release: see P5)
  version_probe: configure.ac:AC_INIT   # fixes P2 for the dev track
  release_notes: Changes                # upstream changelog, read at the tag

dependencies:
  - name: bitwuzla
    repo: https://github.com/bitwuzla/bitwuzla
    policy: branch:main
```

* `release_policy` — how to find the newest upstream release. Absent ⇒ the
  package has no release track and behaves exactly as today. The optional
  `:<regex>` suffix filters candidate tags *before* sorting; `latest-tag`
  without a regex keeps today's behaviour. Verilator gets the explicit
  `^v\d+\.\d+$` filter so a future `v5.052-rc1` or `v5.052-pre` can never be
  mistaken for a release (see §6).
* `release_notes` — optional path to the upstream changelog, used to populate
  the release body on the release track (§4.4).
* `version_probe` — optional `<path>:<key>` telling `resolve-inputs.py` to read
  the in-development version out of the checked-out-ref's file when the policy
  is a branch. For Verilator: `AC_INIT([Verilator],[5.051 ...])` → `5.051`.
  Fetched via the GitHub contents API, the same way the legacy workflow did it.

Dependencies (bitwuzla) keep their normal policy on **both** tracks — a release
build pairs the pinned Verilator tag with the current bitwuzla, and the manifest
records exactly what was used.

### 4.3 `build-release.yml` changes

Add inputs:

```yaml
track:
  description: "dev | release"
  type: string
  default: dev
```

`prerelease` becomes derived rather than caller-supplied
(`release` ⇒ false, `dev` ⇒ true), with the existing `prerelease` input kept as
an override for manual dispatch.

Both tracks' `resolve` jobs evaluate the same predicate:

> **`new_release`** — resolve core with `release_policy` → `v5.050`; then
> `gh release view v5.050`. If our release does *not* exist, `new_release=true`.

This is the whole "is upstream newer than our last release?" test: it is
idempotent, needs no extra state, and survives re-runs, deleted releases, and
manual builds. (An explicit "newer than" numeric comparison is *not* needed —
`latest-tag` only ever names the newest tag, and if we already built it there is
nothing to do.) It is also two API calls, cheap enough for both tracks to ask
independently. The two tracks then take opposite branches on it (§4.6).

`resolve` job, release track:

1. Evaluate `new_release`. If false → `build_needed=false`, stop.
2. `version = strip_v(ref)` → `5.050`; `tag = v5.050`.
3. Resolve dependencies normally; compute the digest for the manifest (recorded,
   but **not** used as the gate on this track — the upstream tag is the identity).

`resolve` job, dev track: unchanged, except

* evaluate `new_release` first — if **true**, `build_needed=false` and stop; the
  release track is handling this run (§4.6),
* version = `<version_probe result>.<build-id>` (fixes P2),
* the previous-manifest fetch selects the newest release **whose manifest
  records `track: dev`**, instead of GitHub's "latest" (fixes P3).

To implement the track-aware previous lookup, `gen-manifest.py assemble` gains
`release.track`, and the fetch step becomes: list releases newest-first, download
each `manifest.json` until one matches the track (bounded to ~10 lookbacks).
Fallback: match on the tag shape — `^v\d+\.\d+$` is release, three-component is
dev — so it also works against manifests written before this change.

`publish` job:

```bash
if [ "$track" = release ]; then
  flags="--latest --notes-file release-notes.md"
else
  flags="--prerelease --latest=false"
fi
```

### 4.4 Release notes on the release track

Verilator publishes no GitHub Releases (P5), so there is no upstream release
body to copy. The equivalent content is the `Changes` file in the repo root,
which is updated *before* the tag: at `v5.050` its newest section is

```
Verilator 5.050 2026-07-01
==========================

**Important:**

* Support covergroups, coverpoints, and bins (#784) ... [Matthew Ballance]
...
```

A `release-notes.py` step in `resolve` (or a small block in `publish`) fetches
`<release_notes>` at the resolved core SHA via the contents API and extracts the
section for the built version: from the line `Verilator <ver> <date>` up to the
next `^Verilator \d` heading. The reStructuredText body is already valid
Markdown for the constructs used (`*` bullets, `**bold:**`, inline `` `code` ``);
only the `===` underline needs dropping, since in Markdown it would promote the
preceding line to an H1.

The emitted body is:

```markdown
Verilator 5.050 (2026-07-01) — built by verilator-bin.

Upstream: https://github.com/verilator/verilator/releases/tag/v5.050

## Upstream changes

<extracted section>
```

Failure is **non-fatal**: if the file is missing or the section cannot be found,
log a warning and publish with the default generated notes. A changelog format
change upstream must not block a release. The dev track gets no notes — a
top-of-trunk snapshot has no changelog section of its own.

### 4.5 Build ID for the dev track

Recommend `${{ github.run_id }}` (what production has published for months and
what every existing tag uses) over the staged pipeline's `date -u +%Y%m%d`.
The date form collides if two builds land on the same day and breaks continuity
with the published tag history. This is a one-line change in the version step.

### 4.6 Track precedence: at most one build per run

A week that produces a release should not also produce a dev snapshot of the
same code — the release *is* the better artifact, and building both doubles
that week's CI minutes for no added coverage.

No sequencing or job-to-job plumbing is needed for this. Both tracks already
evaluate `new_release` in their own `resolve` job (§4.3); they simply branch
opposite ways on it:

| `new_release` | release track | dev track |
|---|---|---|
| true | builds `v5.050` | `build_needed=false` |
| false | `build_needed=false` | normal digest gate |

The predicate is a pure function of upstream tags and our published releases, so
both jobs compute the same answer without talking to each other. They keep
running in parallel, and neither knows the other exists.

Two consequences worth stating:

* If the release build **fails**, that week gets no dev snapshot either — the
  dev track stood down based on the tag, not on the outcome. Recovery is the
  next scheduled run or a manual dispatch. Accepted: a failed release build is
  something we want to look at anyway.
* This is precedence, not a lock. A *manually dispatched* dev build with
  `force: true` still runs alongside a release; the constraint exists to avoid
  redundant scheduled work, not to serialise the repo.

### 4.7 `ci.yml` shape

Call the reusable workflow twice — one job per track, no dependency between
them:

```yaml
jobs:
  release:
    if: github.event_name != 'push'      # tags don't change on a recipe push
    uses: edapack/edapack-common/.github/workflows/build-release.yml@v1
    with:
      package: verilator-bin
      track: release
      targets: |
        [ ... same list ... ]

  dev:
    uses: edapack/edapack-common/.github/workflows/build-release.yml@v1
    with:
      package: verilator-bin
      track: dev
      targets: |
        [ ... unchanged ... ]
      core_ref: ${{ inputs.core_ref || '' }}
      input_overrides: ${{ inputs.input_overrides || '{}' }}
      force: ${{ github.event_name == 'workflow_dispatch' && inputs.force }}
```

The `ci.yml` here is exactly two independent callers — all the track logic lives
in `resolve`, where the inputs are already resolved.

Cost of the extra track: one ~30-second `resolve` job per week when there is no
new upstream tag, running concurrently with the dev track rather than ahead of
it. Verilator tags roughly every 6–8 weeks, so a full release build runs
~8×/year — and in those weeks the dev build is skipped, so the extra track is
close to CI-minute neutral overall.

Add a `track` choice to `workflow_dispatch` so a release can be forced by hand
(e.g. to rebuild `v5.050` after deleting a bad release).

### 4.8 What a release looks like

```
Tag:      v5.050
Title:    verilator-bin 5.050
Latest:   yes            Pre-release: no
Body:     upstream Changes section for 5.050 (§4.4)
Assets:   verilator-manylinux_2_28_x86_64-5.050.tar.gz  (+ .sha256)
          verilator-manylinux_2_34_x86_64-5.050.tar.gz
          verilator-manylinux2014_x86_64-5.050.tar.gz
          verilator-manylinux_2_28_aarch64-5.050.tar.gz
          verilator-manylinux_2_34_aarch64-5.050.tar.gz
          verilator-macos-arm64-5.050.tar.gz
          manifest.json
```

The `targets` matrix is shared with the dev track, so platform coverage cannot
drift between the two.

## 5. Rollout

1. **edapack-common**: re-tag `v1` at `main` (fixes P1). Verify the staged
   `verilator-bin` `ci.yml` runs green on the dev track before adding anything.
2. **edapack-common**: implement `version_probe` (P2) + track-aware previous
   manifest (P3) + `run_id` build ID; unit-test `resolve-inputs` and
   `manifest-diff` offline (the existing tests already inject a fake backend).
3. **edapack-common**: implement `track: release` in `resolve` and `publish`,
   including the `latest-tag:<regex>` policy suffix, the shared `new_release`
   predicate used by both tracks, and `release_notes` extraction (unit-test the
   extractor against the real `Changes` file for several tags).
4. **verilator-bin**: add `release_policy` + `version_probe` + `release_notes`
   to `build-inputs.yaml`; split `ci.yml` into `release` + `dev` jobs with the
   precedence wiring from §4.6.
5. **Dry run**: dispatch `track=release` manually. First run builds `v5.050`
   (upstream newest; we have never released it), publishes it as full release
   with the upstream 5.050 notes, and moves `latest` off the June snapshot.
   Verify the tarballs and the rendered release body before letting the cron
   own it. Confirm the dev job is skipped in that same run.
6. Update `README.md` §Release Scheme to describe the two tracks factually.

## 6. Risks / open questions

**Decided** (were open; recorded here so the rationale survives):

* **`latest` moves automatically.** No human `--latest` flip, no draft stage.
  Upstream Verilator's own test suite is thorough for tagged releases, and our
  `scripts/build.sh` smoke test covers the packaging. Requiring a manual
  promotion would recreate the exact step this design removes. If a bad release
  does land, the recovery is to delete it and dispatch `track=release` by hand,
  which rebuilds the same tag (§4.7).
* **No backfill.** The design only ever builds the *newest* upstream tag; we
  will never have `v5.048` / `v5.046` artifacts. Accepted — the track only moves
  forward.
* **One build per cron run.** The dev snapshot stands down in a week where a new
  upstream tag exists. Both tracks test the same condition independently and
  branch opposite ways; see §4.6.
* **Release tags are filtered.** `release_policy` carries an explicit
  `^v\d+\.\d+$` regex (§4.2), so a future `v5.052-rc1` cannot be picked up by
  `latest-tag` and published as `5.052`.

**Still open:**

* **Stable download URL.** `releases/latest/download/<file>` still requires the
  consumer to know the version string. If downstream tooling wants a
  version-independent URL, we would need to also upload a
  `verilator-<plat>-latest.tar.gz` alias. Not included — flag if wanted.
* **Changelog format drift.** The release-notes extraction depends on the
  `Verilator <ver> <date>` / `===` heading shape in `Changes`. It is stable
  across all 338 tags, and failure degrades to default notes rather than
  blocking the release (§4.4), so this is a cosmetic risk only.

## 7. Implementation notes

Where the built code differs from the design above:

* **`prerelease` is derived on the release track, not overridable.** A
  `workflow_call` input cannot distinguish "unset" from "default", so a
  caller-supplied `prerelease` would have to be respected on every run —
  making the release track pre-release by default. It is therefore forced
  false on the release track and still honored on the dev track.
* **`version_probe` reads at the resolved SHA, not the ref.** The branch can
  move between `ls-remote` and the contents read; the version must describe the
  commit actually recorded and built.
* **`core.release_notes` rides in `candidate.json`.** `resolve-inputs.py`
  carries the path through, so the publish step needs no second YAML parse.
* **`gen-manifest.py track`** is a third subcommand exposing `track_of()`, so
  the previous-manifest walk is a plain string compare in shell rather than
  inline Python in the workflow.
* **`ci.yml` dispatch takes `track: both | dev | release`**, so either track
  can be run alone by hand.

Verified offline (`make test`, 67 passing) and against live upstream:

* dev track resolves core `master` → version **5.051** (P2 fixed; previously
  `None` → `0.<build-id>`),
* release track resolves core → **v5.050**, version `5.050`,
* `latest-tag:^v\d+\.\d+$` selects `v5.050` even with a `v5.052-rc1` tag
  present, which bare `latest-tag` would have picked,
* release notes extract cleanly for 5.050/5.048/5.046/5.044 and soft-fail
  (exit 2) for an absent version.
