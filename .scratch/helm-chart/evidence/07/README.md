# Helm chart ticket 07 evidence

Evidence for [ticket 07](../../issues/07-attest-published-chart.md)'s box 2: `gh attestation verify` on the first release that carries attestations, the prerelease `v0.3.1-rc.1`.

- [verify.sh](verify.sh) `<image digest> <chart digest>`, with both digests from the run summary, into [verify.txt](verify.txt). It verifies each digest from GitHub's attestations API and, with `--bundle-from-oci`, from ghcr.io, each signed by `release.yml` in `BiscuitBin/knarr`, then checks that the chart's stamped `image.digest` is the image digest. Lines beginning `ok` are checked. Run it with `.pixi/envs/default/bin` first on `PATH`, for the project's helm.
- [signer-case.txt](signer-case.txt): the same image verify with the owner spelt `biscuitbin` and `BiscuitBin` in `--signer-workflow`, and the certificate's workflow URI.

It reaches GitHub, ghcr.io and Sigstore's public-good instance, so each run needs the maintainer's authorization.

## The run

On 2026-10-27, with gh 2.100.0 and helm 4.3.0, against release run [40437088789](https://github.com/BiscuitBin/knarr/actions/runs/40437088789) for `v0.3.1-rc.1` at `b71fd32`:

| Subject | Digest | GitHub attestation | Rekor log index |
| --- | --- | --- | --- |
| `ghcr.io/biscuitbin/knarr` | `sha256:747f9fc7f61982a3caac6de01355e40e1e0cc15db12aefeca13f68045b8b004c` | [60191062](https://github.com/BiscuitBin/knarr/attestations/60191062) | [3502443414](https://search.sigstore.dev?logIndex=3502443414) |
| `ghcr.io/biscuitbin/charts/knarr` | `sha256:4870df80ebe285b4dbef53c6175d43f4cf08dc2fff19c4b5c798231da349a6b2` | [60191101](https://github.com/BiscuitBin/knarr/attestations/60191101) | [3502447444](https://search.sigstore.dev?logIndex=3502447444) |

Both attest steps logged "Attestation uploaded to registry". `verify.txt` ends `verify passed`: all four verifies, including the chart's from ghcr.io with `--bundle-from-oci`, and the chart's stamped `image.digest` is the image digest. ghcr.io and `gh` take an attestation on a Helm chart's OCI artifact.

**Finding: the owner's case.** The first run, with the lowercase owner in `--signer-workflow` that the install guide carried, failed on the image with only `Error: verifying with issuer "sigstore.dev"`. The certificate's workflow URI is `https://github.com/BiscuitBin/knarr/.github/workflows/release.yml@refs/tags/v0.3.1-rc.1`, and `--signer-workflow` matches it with case; `--repo` does not. `verify.sh` and the install guide now spell the owner `BiscuitBin`.

**Time.** The publish job ran 79 s, against 58 s for `v0.3.0` ([40068527393](https://github.com/BiscuitBin/knarr/actions/runs/40068527393)). The image's attest step took 11 s and the chart's 8 s.
