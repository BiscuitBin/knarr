# Helm chart ticket 07 evidence

Evidence for [ticket 07](../../issues/07-attest-published-chart.md)'s box 2: `gh attestation verify` on the first release that carries attestations, the prerelease `v0.3.1-rc.1`.

- [verify.sh](verify.sh) `<image digest> <chart digest>`, with both digests from the run summary, into `verify.txt`. It verifies each digest from GitHub's attestations API and, with `--bundle-from-oci`, from ghcr.io, each signed by `release.yml` in `biscuitbin/knarr`, then checks that the chart's stamped `image.digest` is the image digest. Lines beginning `ok` are checked.

It reaches GitHub and ghcr.io, so each run needs the maintainer's authorization. The run, the transcript and the network used are recorded here after the release.
