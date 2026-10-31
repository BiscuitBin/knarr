# Bootstrap ticket 54 evidence

Evidence for [ticket 54](../../issues/54-release-v0-3-1.md): the release of `v0.3.1`, through the route tickets [37](../37/README.md) and [40](../40/README.md) ran and [org transfer 05](../../../org-transfer/evidence/05/README.md) followed. Each script's transcript sits beside it, from the runs on 2026-10-30 and 2026-10-31 UTC listed below. The release is run [41016018897](https://github.com/BiscuitBin/knarr/actions/runs/41016018897): image `ghcr.io/biscuitbin/knarr@sha256:8b89fd1c08c5170bec456df522d48e7b78431859d7c135993fc14327533ea385`, chart `ghcr.io/biscuitbin/charts/knarr:0.3.1` at `sha256:1c4d28f935009f6306450b13758fb60866a596cc4b1c4f0d02359a69343ae013`.

Each script exits non-zero on an unexpected result. Lines beginning `ok` are checked, and lines beginning `info` only report. Each header comment says what changed from the script it adapts. In order:

- `just release-preflight v0.3.1 <merge commit>`, after `git fetch`, on the UTC day the changelog heading names, into [preflight.txt](preflight.txt).
- [run.sh](run.sh) `<run-id> v0.3.1 <commit>`, adapted from org transfer 05's, reads the run back into [run.txt](run.txt): both jobs green, the approval, every existence guard `absent (http 404)`, exactly the tags `0.3.1`, `0.3` and `sha-6e2428c`, one image digest, the chart stamped with it and pushed, both attest steps green with how long each took, their `Attestation created for` lines naming exactly the image and the chart at those digests, and the annotated tag on the remote.
- [verify.sh](verify.sh) `<image digest> <chart digest>`, adapted from helm chart 07's, runs the install guide's "Verify a release" commands into [verify.txt](verify.txt): `gh attestation verify` for both digests, from GitHub and with `--bundle-from-oci` from ghcr.io, with `--signer-workflow BiscuitBin/knarr/.github/workflows/release.yml`, then the guide's `helm show values … | grep 'digest:'`, which must print the image digest.
- [scan.sh](scan.sh) `<v0.3.1 image digest> <rc.1 image digest>` pulls both amd64 images by digest and runs `just image-scan` and `just runtime-scan` on each into [scan.txt](scan.txt). `v0.3.1-rc.1`'s image, `sha256:747f9fc7f61982a3caac6de01355e40e1e0cc15db12aefeca13f68045b8b004c`, is the control: it predates ticket 52 and should still list CVE-2026-94200. rebar3 is not in the runtime image, so neither scan ever matched it, and ticket 53's fix does not show here.

## Network the maintainer authorized for this ticket

Each separately, on 2026-10-30 UTC:

- `just initialize` in this worktree.
- The push of branch `54-release-v0-3-1` and `gh pr create` for pull request #72, then `gh pr checks` on it. The maintainer merged #72 as `6e2428c`.
- `git fetch origin`.
- `just release-preflight v0.3.1 6e2428ced066ebb05b9b73a0be12825550f3488e` ([preflight.txt](preflight.txt)), with `git ls-remote --tags` to confirm no `v0.3.1` existed.
- The push of the annotated tag `v0.3.1` (message `v0.3.1`, object `95b0b89`) on `6e2428c`.
- `gh run list`, `gh run view` and `gh run watch` for run 41016018897. The maintainer approved the `release` environment in GitHub's UI.
- `run.sh` twice ([run.txt](run.txt) held the second until the rerun below). The first ran while the publish job still waited for approval, because a `gh run watch` that timed out on the network was read as the run finishing. It stopped at `status, conclusion: read 'waiting '`.
- `verify.sh` ([verify.txt](verify.txt)).
- `just audit-install`, then `scan.sh` ([scan.txt](scan.txt)), with its two image pulls and grype's database download.
- A read-only `git fetch --tags` for the hand-back's `git diff v0.3.0 v0.3.1`. It was not separately authorized, and it fetched nothing new.

Then, on 2026-10-31 UTC, after the review of pull request #73 made `run.sh`'s durations portable and `scan.sh` require the control's exit 2:

- `run.sh` again, which replaced [run.txt](run.txt). Only its `date:` line changed.
- `scan.sh` again, with its two image pulls and grype's database check, which replaced [scan.txt](scan.txt). The database was still the one built 2026-10-30T06:23Z, and only the `date:` line changed.

## Rerun

Every script but the preflight reaches the network, and each run needs authorization:

```sh
E=.scratch/bootstrap/evidence/54
T=v0.3.1
C=6e2428ced066ebb05b9b73a0be12825550f3488e
D=sha256:8b89fd1c08c5170bec456df522d48e7b78431859d7c135993fc14327533ea385
H=sha256:1c4d28f935009f6306450b13758fb60866a596cc4b1c4f0d02359a69343ae013
R=sha256:747f9fc7f61982a3caac6de01355e40e1e0cc15db12aefeca13f68045b8b004c
export PATH="$PWD/.pixi/envs/default/bin:$PATH"
sh "$E/run.sh" 41016018897 "$T" "$C" > "$E/run.txt" 2>&1
sh "$E/verify.sh" "$D" "$H" > "$E/verify.txt" 2>&1
sh "$E/scan.sh" "$D" "$R" > "$E/scan.txt" 2>&1
```

A rerun of `scan.sh` reads a newer grype database, so its tables can list advisories published since.
