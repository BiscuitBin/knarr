# Ticket 40 evidence

Evidence for [ticket 40](../../issues/40-mvp-release.md), the MVP release through the route [ticket 37](../37/README.md) proved. Gathered on 2026-10-20 and 2026-10-21 (UTC) with gh 2.100.0, logged in as `steven-cutting`, on the maintainer's Apple arm64 host with OrbStack's Docker 29.4.0. Every step that left the worktree was authorized by the maintainer, one action at a time.

The release is `v0.2.0`, an annotated tag (object `b770ce3d85db22bdf4338abe71aed32211af29e9`) on `c917c2ebdef75d31bd455f30a5d33ea4fcd96081`, the merge commit of pull request #53. [Run 39551271680](https://github.com/steven-cutting/knarr/actions/runs/39551271680) published `ghcr.io/steven-cutting/knarr@sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9` under `0.2.0`, `0.2` and `sha-c917c2e`, and the chart `ghcr.io/steven-cutting/charts/knarr:0.2.0` at `sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016`, with that image digest stamped in. It is the first release with a chart: helm chart ticket 04 added the chart's steps to `publish` after 37 ran.

Each script exits non-zero on an unexpected result. Lines beginning `ok` are checked, and lines beginning `info` only report. `run.sh`, `public.sh` and `pull.sh` are adapted from 37's, and each header comment says what changed; 37's scripts and transcripts stay as they ran. `public.sh` sources [`scripts/release/lib.sh`](../../../../scripts/release/lib.sh), the file `release.yml` sources. In order:

- [settings.sh](settings.sh), copied from 37's with its tag expectation changed, reads the `release` environment, the rulesets, the tags and the releases before the tag, and prints each answer raw before checking it. [settings.txt](settings.txt), at 2026-10-20T00:21Z with ruleset `25048585`: ticket 36's environment unchanged (one required reviewer, the maintainer, and "Prevent self-review" off), the one `v*` tag ruleset as 37 made it, the one tag `v0.1.0`, and no GitHub release.
- [preflight.txt](preflight.txt) is `just release-preflight`, the promotion of 37's `preflight.sh` into [`scripts/release/preflight.sh`](../../../../scripts/release/preflight.sh), run offline at 2026-10-21T05:43Z on the commit about to be tagged: it is `origin/main`, the version is `0.2.0`, the changelog has `## [0.2.0] - 2026-10-21`, the chart packages for that version, there is no local `v0.2.0` yet, and the tag set is `0.2.0`, `0.2` and `sha-c917c2e`.
- [run.sh](run.sh) reads the run back: its jobs, the environment's approval, the lines of each log the hand-back cites, and the tag as this clone and the remote hold it. Each answer is read once, and the lines it prints are the lines it checks. It prints no whole log. [run.txt](run.txt), at 05:51Z: `verify` passed its guards, the maintainer approved `release` with the comment "Approved by the maintainer for v0.2.0 (ticket 40)", the chart packaged with the placeholder digest before anything was pushed, the image's existence guard read `absent (http 404)`, and so did the chart's guard, both before the image push and before the chart push; buildx named and pushed exactly `0.2.0`, `0.2` and `sha-c917c2e`; the log has one image digest; the stamped package names it; helm printed `Pushed: ghcr.io/steven-cutting/charts/knarr:0.2.0` and one `Digest:`, which `chart_digest=` repeats; neither job has an error line; and the tag is annotated on the remote as well. Two of 37's checks no longer fit as written: `publish` now logs in twice, to docker and to helm's registry, so two `Login Succeeded` lines are expected where 37 expected one; and the existence-guard pattern now matches the chart's two guard lines too, so the image's line is selected by its repository. The chart checks are new.
- [public.sh](public.sh) reads the image and the chart as anyone sees them, with no credentials. 37's `private` mode is dropped, since 37 found the package public from its first push. [public.txt](public.txt), at 05:51:26Z: for the image, the anonymous token is granted, every pushed tag and the digest itself answer 200 with the run's digest, `latest` 404, `0.1.0` and `0.1` still answer with 0.1.0's digest, `tags/list` holds exactly 0.2.0's three tags and 0.1.0's three, and the existence guard reads `present` for `0.2.0`. For the chart, `steven-cutting/charts/knarr` grants an anonymous token too, so the new package is public with no step; `0.2.0` and the chart digest answer 200 with the run's chart digest, `latest` 404, and `tags/list` holds only `0.2.0`. The manifest's bytes hash to the chart digest, its one layer hashes to the digest it names, and that layer's `Chart.yaml` and `values.yaml` carry version and appVersion `0.2.0`, repository `ghcr.io/steven-cutting/knarr`, tag `"0.2.0"`, `IfNotPresent` and the image digest. The existence guard reads `present` for the chart's `0.2.0` as well. The first run, at 05:51:13Z and unsaved, failed at the layer's media type: the script expected `application/vnd.cncf.helm.chart.content.v1.tar.gz`, and helm writes `…v1.tar+gzip`. The expectation was corrected and the script rerun; nothing else changed.
- [pull.sh](pull.sh) pulls the digest in a fresh `docker:29.4.0-dind` container: a daemon that never built the image, with an empty image store and no credentials. The host is arm64 and the image amd64 only, so the pull names the platform and nothing runs the image. [pull.txt](pull.txt), at 05:51:42Z: every layer is pulled, the labels read version `0.2.0` and revision `c917c2e…`, `created` is `2026-10-21T05:45:19Z` (stamped when `publish` built, after the approval), the platform is `linux/amd64`, and the container is removed.

`run.sh` was run twice: the second run, at 05:51Z, only corrected a check's label (`chart_digest= agrees with the Digest: line`), and read the same run.

The digest 39 installs is `sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9`, or the chart `oci://ghcr.io/steven-cutting/charts/knarr --version 0.2.0`, which pins it.

## Network the maintainer authorized for this ticket

Each separately: the merges of pull requests #52 and #53, by the maintainer; `git fetch origin`; the `settings.sh` run; the push of tag `v0.2.0`, by the maintainer, after `just release-preflight` passed offline; `gh run list`, `gh run view` and `gh run watch` for the run; the approval of the `release` deployment, by the maintainer's own gh login through `gh api -X POST repos/steven-cutting/knarr/actions/runs/39551271680/pending_deployments`; then, with read-only `gh` calls about the run and anonymous reads of ghcr.io, the `gh run view` reads of the run and the publish job's log that shaped `run.sh`'s patterns, two `run.sh` runs, two `public.sh` runs (the first failed, as above), and `pull.sh`, its anonymous pull from ghcr.io in a fresh `docker:29.4.0-dind` container already on the host.

## Rerun

Every script but the preflight reaches the network, and each run needs authorization:

```sh
E=.scratch/bootstrap/evidence/40
T=v0.2.0
C=c917c2ebdef75d31bd455f30a5d33ea4fcd96081
D=sha256:989cb9e44df4b97960e68371c1ae8bddcd29db99d65bbd09b663776665c01bc9
H=sha256:3f29bcaccaf932c492ec9bb06db53c2f0e273232fdbea50aa6bdba681caa9016
just release-preflight $T $C   # offline; fails now that a local v0.2.0 exists, by design
sh $E/settings.sh 25048585     # fails now that v0.2.0 exists: it expects only v0.1.0
sh $E/run.sh 39551271680 $T $C
sh $E/public.sh $T $C $D $H
sh $E/pull.sh $D $C 0.2.0      # needs docker:29.4.0-dind on the host
```

The preflight and `settings.sh` record the state before the tag, and both refuse to pass once it exists. That is their purpose, and a rerun now shows the tag.
