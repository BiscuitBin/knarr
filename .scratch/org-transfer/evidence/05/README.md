# Org transfer ticket 05 evidence

Evidence for [ticket 05](../../issues/05-first-release-under-org.md), the first release under the org, `v0.3.0`, through the route bootstrap tickets [37](../../../bootstrap/evidence/37/README.md) and [40](../../../bootstrap/evidence/40/README.md) ran. Each script's transcript sits beside it, from the runs on 2026-10-24 UTC listed under the network section below. The release is run [40068527393](https://github.com/BiscuitBin/knarr/actions/runs/40068527393): image `ghcr.io/biscuitbin/knarr@sha256:a0758098d2e2a28ea528ac8bf4b8f675b61f2a75d375e60995afb6a82d22db84`, chart `ghcr.io/biscuitbin/charts/knarr:0.3.0` at `sha256:1500c5139ff5fbff7c658d2f001d9b7e421ff9435333ad28df7aa5f86d6bb2b7`.

Each script exits non-zero on an unexpected result. Lines beginning `ok` are checked, and lines beginning `info` only report. `settings.sh`, `run.sh`, `public.sh` and `pull.sh` are adapted from 40's; `anonymous-pull.sh` and `upgrade.sh` from helm chart ticket 05's [19](../../../helm-chart/evidence/05/19-published-anonymous-pull.sh) and [15](../../../helm-chart/evidence/05/15-published-install-upgrade.sh). Each header comment says what changed. 37's, 40's and helm chart 05's scripts and transcripts stay as they ran. In order:

- [settings.sh](settings.sh) `before 25048585` (the `v*` tag ruleset's id) reads the `release` environment, the rulesets, the tags and the releases before the tag, into `settings.txt`: ticket 36's environment carried over the transfer, the one `v*` tag ruleset, exactly the tags `v0.1.0` and `v0.2.0`, and no GitHub release.
- `just release-preflight v0.3.0 <merge commit>`, offline, after `git fetch`, on the UTC day the changelog heading names, into `preflight.txt`.
- [run.sh](run.sh) `<run-id> v0.3.0 <commit>` reads the run back into `run.txt`: both jobs green, the approval, both packages' existence guards `absent (http 404)`, exactly three image tags, one image digest, the chart stamped with it and pushed, and the annotated tag on the remote.
- [public.sh](public.sh) `v0.3.0 <commit> <image digest> <chart digest>` reads both new packages with no credentials into `public.txt`. A refused anonymous token, or a token whose manifest read is refused, is the not-public outcome: the script names the package and stops, the maintainer makes it public by hand, and the script is rerun. It also checks that 0.2.0 still answers at its digests under `steven-cutting`.
- [settings.sh](settings.sh) `packages`, into `packages.txt`: each package as GitHub returns it, public and linked to `BiscuitBin/knarr`. With `settings.txt`, it records the package settings the ticket asks for, in 37's shape, which read them from the settings page.
- [pull.sh](pull.sh) `<image digest> <commit> 0.3.0` pulls the image by digest on a fresh `docker:29.4.0-dind` daemon with no credentials, into `pull.txt`.
- [anonymous-pull.sh](anonymous-pull.sh) `0.3.0 <chart digest> <image digest>`, under `sh -x`, pulls the chart by digest with empty Helm and Docker configuration, into `anonymous-pull.txt`.
- [upgrade.sh](upgrade.sh) `<image digest>`, under `sh -x`, on a fresh kind cluster: `v0.2.0` from `oci://ghcr.io/steven-cutting/charts/knarr`, fake workers opted in, then `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0`, into `upgrade.txt`. It needs the fake worker image (`just fake-worker-image-build`).

The org allows members to create public packages ([org.txt](../02/org.txt); see the network section for the change this ticket needed), and `release.yml`'s `publish` job asks for `packages: write`.

## Network the maintainer authorized for this ticket

Each separately, on 2026-10-24 UTC: the merge of pull request #61, by the maintainer, as `7c88ec9`; `git fetch origin`; `settings.sh before 25048585` ([settings.txt](settings.txt)); `just release-preflight v0.3.0 7c88ec9c982b8eee33cc8d38f34e327c7b2f9acb`, offline ([preflight.txt](preflight.txt)); the push of the annotated tag `v0.3.0` (message `v0.3.0`, object `03172b2`) on `7c88ec9`; `gh run list`, `gh run view` and `gh run watch` for run 40068527393; the approval of the `release` deployment with the maintainer's own gh login through `gh api -X POST repos/biscuitbin/knarr/actions/runs/40068527393/pending_deployments -F 'environment_ids[]=23921538204' -f state=approved`. The plan named `25048585` as the environment id. That is the tag ruleset's id; the `release` environment's id, in `settings.txt` and in the run's pending deployment, is `23921538204`, and the approval used it.

Then, with read-only `gh` calls and anonymous reads of ghcr.io:

- `run.sh` ([run.txt](run.txt)).
- `public.sh` twice ([public.txt](public.txt) is the second). The first stopped at the named not-public outcome: ghcr.io refused an anonymous token for `biscuitbin/knarr` with http 401, and a direct anonymous token request for `biscuitbin/charts/knarr` was refused the same way. Both packages were private from their first push, unlike 37's. Under Settings → Member privileges → Package creation, the maintainer allowed org members to create public and internal packages, then made each package public by hand. Ticket 02's UI reading ([org.txt](../02/org.txt), line 53) recorded that setting as "public allowed", but public visibility was not available here until the maintainer changed it. This evidence cannot tell whether 02's reading was wrong or the setting changed after it. The second run passed.
- `settings.sh packages` twice ([packages.txt](packages.txt) is the second). The first failed with http 403: the gh token lacked `read:packages`. The maintainer added it with `gh auth refresh -s read:packages`.
- `pull.sh` ([pull.txt](pull.txt)), in a fresh `docker:29.4.0-dind` container already on the host.
- `anonymous-pull.sh` three times ([anonymous-pull.txt](anonymous-pull.txt) is the third). The first ran without the worktree pixi PATH and found no `helm`. The second pulled the chart at its digest, then failed: Helm 4 names a chart pulled by digest `knarr@sha256-<hex>.tgz`, not `knarr-<version>.tgz`. The script now reads the one file the pull wrote, as its header says.
- `just fake-worker-image-build`, then `upgrade.sh` twice ([upgrade.txt](upgrade.txt) is the second). The first stopped before any cluster existed because the `cluster` pixi environment was not installed; the maintainer ran `pixi install --locked -e cluster`. The second created a kind cluster, installed `v0.2.0` from `oci://ghcr.io/steven-cutting/charts/knarr`, opted in fake workers and upgraded to `oci://ghcr.io/biscuitbin/charts/knarr` 0.3.0.

## Rerun

Every script but the preflight reaches the network, and each run needs authorization:

```sh
E=.scratch/org-transfer/evidence/05
T=v0.3.0
C=7c88ec9c982b8eee33cc8d38f34e327c7b2f9acb
D=sha256:a0758098d2e2a28ea528ac8bf4b8f675b61f2a75d375e60995afb6a82d22db84
H=sha256:1500c5139ff5fbff7c658d2f001d9b7e421ff9435333ad28df7aa5f86d6bb2b7
just release-preflight $T $C          # offline; fails now that v0.3.0 exists, by design
sh $E/settings.sh before 25048585     # fails now that v0.3.0 exists: it expects only v0.1.0 and v0.2.0
sh $E/run.sh 40068527393 $T $C
sh $E/public.sh $T $C $D $H
sh $E/settings.sh packages            # needs a token with read:packages
sh $E/pull.sh $D $C 0.3.0             # needs docker:29.4.0-dind on the host
PATH="$PWD/.pixi/envs/default/bin:$PATH" sh -x $E/anonymous-pull.sh 0.3.0 $H $D
sh -x $E/upgrade.sh $D                # needs just fake-worker-image-build and the cluster pixi environment
```
