# Ticket 37 evidence

Evidence for [ticket 37](../../issues/37-first-release-v0-1-0.md), the first run of the release route, and for the "Amended by ticket 37" notes in [Decision 0012: Release and packaging](../../../../docs/decisions/0012-release-and-packaging.md). Gathered on 2026-10-14 (UTC) with gh 2.100.0, logged in as `steven-cutting`, on the maintainer's Apple arm64 host with OrbStack's Docker 29.4.0. Every step that left the worktree was authorized by the maintainer, one action at a time.

The release is `v0.1.0`, an annotated tag on `283a7d489d07d81bd3a9c393ce10be11ad71303f`, the merge commit of pull request #33. [Run 38506839202](https://github.com/steven-cutting/knarr/actions/runs/38506839202) published `ghcr.io/steven-cutting/knarr@sha256:97262e02b6326b73ac414fa1bb01b6f557b1c352b7d647a30d7835e4a59e22c7` under `0.1.0`, `0.1` and `sha-283a7d4`.

Each script exits non-zero on an unexpected result. Lines beginning `ok` are checked, and lines beginning `info` only report. The scripts that read the release guards source [`scripts/release/lib.sh`](../../../../scripts/release/lib.sh), the file `release.yml` sources. In order:

- [preflight.sh](preflight.sh) runs `verify`'s guards offline on the commit about to be tagged, reading `gleam.toml` and `CHANGELOG.md` with `git show`. The tag ruleset makes a pushed `v0.1.0` permanent, so the guards ran first. [preflight.txt](preflight.txt): the version is `0.1.0`, the commit is `origin/main`, the changelog has `## [0.1.0] - 2026-10-14`, and the tag set is `0.1.0`, `0.1` and `sha-283a7d4`.
- [settings.sh](settings.sh) reads the `release` environment, the rulesets, the tags and the releases, and prints each answer raw before checking it. Run once with no argument, unsaved, at 03:29Z, it read no ruleset. Then [ruleset.json](ruleset.json) went to `POST repos/steven-cutting/knarr/rulesets`, and [ruleset-response.json](ruleset-response.json) is GitHub's answer: ruleset `25048585`, `"current_user_can_bypass": "never"`. [settings.txt](settings.txt) is the record taken with that id before the tag: ticket 36's environment unchanged, the one ruleset as sent, no tag, and no release.
- [run.sh](run.sh) reads the run back: its jobs, the environment's approval, the lines of each log the hand-back cites, and the tag as this clone and the remote hold it. It prints no whole log. [run.txt](run.txt): `verify` passed, the maintainer approved `release`, the existence guard read `absent (http 404)`, three tags were pushed, and the tag is annotated on the remote as well.
- [public.sh](public.sh) reads the package as anyone sees it, with no credentials. Its `private` mode expected 0012's account: a package that does not inherit the repository's visibility, so the anonymous pull token is refused. [public-private.txt](public-private.txt) is that mode failing its first expectation at 04:33:15Z, before anyone had touched the package: ghcr.io granted the anonymous token, 200. The failure is the finding, so the transcript is kept as it ran. The maintainer then opened the package's settings at about 04:43Z, changed nothing, and saw it public and linked to `steven-cutting/knarr`. [public.txt](public.txt), the `public` mode at 04:47:31Z, shows every pushed tag and the digest itself answering 200 with the run's digest, `latest` 404, `tags/list` holding exactly the three tags, and the existence guard reading `present` for `0.1.0`: the dry line for a second push.
- [pull.sh](pull.sh) pulls the digest in a fresh `docker:29.4.0-dind` container: a daemon that never built the image, with an empty image store and no credentials. The host is arm64 and the image amd64 only, so the pull names the platform and nothing runs the image. [pull.txt](pull.txt): every layer is pulled, the labels read version `0.1.0` and revision `283a7d4…`, the platform is `linux/amd64`, and the container is removed.

## Network the maintainer authorized for this ticket

On 2026-10-14 (UTC), each separately: two pushes of the branch and pull request #33, an edit of its description, `gh pr checks` and the merge; `git fetch origin` and `gh pr view 33`; both `settings.sh` runs and the ruleset `POST`; the tag push, by the maintainer; `gh run list` and `gh run watch`; the approval, by the maintainer; both `run.sh` runs (the first matched a line of the workflow's echoed script, so the pattern was narrowed); `public.sh` three times (`private`, a `public` probe into `ai_tmp/`, then `public.txt`); `docker pull docker:29.4.0-dind` from Docker Hub; `pull.sh`; and `just cluster-install`, by the maintainer, for `just release-pin`. Then the push of this branch and its pull request.

## Rerun

Every script but `preflight.sh` reaches the network, and each run needs authorization:

```sh
E=.scratch/bootstrap/evidence/37
D=sha256:97262e02b6326b73ac414fa1bb01b6f557b1c352b7d647a30d7835e4a59e22c7
C=283a7d489d07d81bd3a9c393ce10be11ad71303f
sh $E/preflight.sh $C          # offline; fails once a local v0.1.0 exists, by design
sh $E/settings.sh 25048585     # fails now that v0.1.0 exists: it expects no tag
sh $E/run.sh 38506839202
sh $E/public.sh $D $C public
sh $E/pull.sh $D $C            # needs docker:29.4.0-dind on the host
```

`preflight.sh` and `settings.sh` record the state before the tag, and both refuse to pass once it exists. That is their purpose, and a rerun now shows the tag.
