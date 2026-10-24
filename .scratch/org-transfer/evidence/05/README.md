# Org transfer ticket 05 evidence

Evidence for [ticket 05](../../issues/05-first-release-under-org.md), the first release under the org, `v0.3.0`, through the route bootstrap tickets [37](../../../bootstrap/evidence/37/README.md) and [40](../../../bootstrap/evidence/40/README.md) ran. The scripts are written; no transcript exists yet. Each transcript is added beside its script when the maintainer authorizes the run.

Each script exits non-zero on an unexpected result. Lines beginning `ok` are checked, and lines beginning `info` only report. `settings.sh`, `run.sh`, `public.sh` and `pull.sh` are adapted from 40's; `anonymous-pull.sh` and `upgrade.sh` from helm chart ticket 05's [19](../../../helm-chart/evidence/05/19-published-anonymous-pull.sh) and [15](../../../helm-chart/evidence/05/15-published-install-upgrade.sh). Each header comment says what changed. 37's, 40's and helm chart 05's scripts and transcripts stay as they ran. In order:

- [settings.sh](settings.sh) `before 25048585` reads the `release` environment, the rulesets, the tags and the releases before the tag, into `settings.txt`: ticket 36's environment carried over the transfer, the one `v*` tag ruleset, exactly the tags `v0.1.0` and `v0.2.0`, and no GitHub release.
- `just release-preflight v0.3.0 <merge commit>`, offline, after `git fetch`, on the UTC day the changelog heading names, into `preflight.txt`.
- [run.sh](run.sh) `<run-id> v0.3.0 <commit>` reads the run back into `run.txt`: both jobs green, the approval, both packages' existence guards `absent (http 404)`, exactly three image tags, one image digest, the chart stamped with it and pushed, and the annotated tag on the remote.
- [public.sh](public.sh) `v0.3.0 <commit> <image digest> <chart digest>` reads both new packages with no credentials into `public.txt`. A refused anonymous token, or a token whose manifest read is refused, is the not-public outcome: the script names the package and stops, the maintainer makes it public by hand, and the script is rerun. It also checks that 0.2.0 still answers at its digests under `steven-cutting`.
- [settings.sh](settings.sh) `packages`, into `packages.txt`: each package as GitHub returns it, public and linked to `BiscuitBin/knarr`. With `settings.txt`, it records the package settings the ticket asks for, in 37's shape, which read them from the settings page.
- [pull.sh](pull.sh) `<image digest> <commit> 0.3.0` pulls the image by digest on a fresh `docker:29.4.0-dind` daemon with no credentials, into `pull.txt`.
- [anonymous-pull.sh](anonymous-pull.sh) `0.3.0 <chart digest> <image digest>`, under `sh -x`, pulls the chart by digest with empty Helm and Docker configuration, into `anonymous-pull.txt`.
- [upgrade.sh](upgrade.sh) `<image digest>`, under `sh -x`, on a fresh kind cluster: `v0.2.0` from `oci://ghcr.io/steven-cutting/charts/knarr`, fake workers opted in, then `helm upgrade knarr oci://ghcr.io/biscuitbin/charts/knarr --version 0.3.0`, into `upgrade.txt`. It needs the fake worker image (`just fake-worker-image-build`).

The org allows members to create public packages ([org.txt](../02/org.txt)), and `release.yml`'s `publish` job asks for `packages: write`.

## Network the maintainer authorized for this ticket

None yet. Each action is listed here as it is authorized and taken.
