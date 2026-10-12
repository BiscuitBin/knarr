---
title: "Run the walking skeleton locally"
kind: "how-to"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["local_cluster_loop"]
requires: []
---

# Run the walking skeleton locally

## Setup and deployment

Install the repository tools with `just initialize`, then the optional cluster
environment with `pixi install --locked -e cluster`. These operations download
packages; agents need explicit network authorization. Docker must be running.
The image build also downloads its locked build dependencies and base images.

Run `just cluster-up`, `just image-build`, `just deploy`, then `just smoke`.
On an Apple-silicon host the image build fails under emulation;
[Image and checks](#image-and-checks) says why and what runs in CI instead.
The default runner is kind. The default image tag is derived from the physical
worktree path, so separate worktrees do not overwrite each other's image.
`just deploy` loads that image, renders its tag into the deployment, applies it
and waits for rollout. The pod template includes the image ID, so rebuilding
the same local tag triggers a fresh rollout. `just smoke` checks health, readiness and metrics over
a temporary loopback port forward, then stops the forwarding process.

The application listens on port 8080. GET `/healthz` returns 200 while the
listener is available; GET `/readyz` returns 200 after startup completes.
GET `/metrics` exports the startup counter and VM metrics. Other paths return
404; other methods on these paths return 405. A supervised listener recovers
from a crash; exceeding two restarts in five seconds exits the VM unsuccessfully. Startup failure causes an unsuccessful application exit.

## Isolation and cleanup

All cluster state is under ignored `.cluster/`, including the kubeconfig's
admin client key. Commands replace any inherited KUBECONFIG and use a name
formed from the worktree basename plus an eight-character path hash. Names
are at most 32 characters. Commands refuse a missing local kubeconfig and remove inherited in-cluster
service environment variables. No recipe changes the user's default kubeconfig.
The naming algorithm lowercases paths, so paths differing only by case share
a cluster name even on a case-sensitive filesystem.

Keep the cluster across test runs. `just cluster-down` deletes only the selected
runner's named cluster and removes its local state after deletion succeeds.
Changing runners requires tearing down the previous runner first; a marker
prevents overwriting its state. Use `just cluster-diagnostics` for pods, events and application logs.

`KNARR_CLUSTER=kwok just cluster-up` creates the simulated tier;
`KNARR_CLUSTER=kwok just cluster-ready` checks node and ServiceAccount readiness.
Use the same runner when tearing it down. kwok has no running worker containers,
so image loading, deployment and endpoint smoke require kind. Its API server
port is selected dynamically, but the selection-to-bind race remains: retry
startup if another process takes that port. kwok publishes it on all interfaces,
as recorded in [Decision 0007](../decisions/0007-local-cluster.md).

## Image and checks

The image is a Gleam erlang-shipment with the locked pixi runtime environment,
copied at its original absolute prefix. The image targets linux/amd64, the
locked CI platform. On an Apple-silicon host, OTP 29's amd64 BEAM fails under
Rosetta in `prim_tty`, both when the image is built and when it runs, so the
image is built and the kind proofs run in CI
([Decision 0012](../decisions/0012-release-and-packaging.md),
[Decision 0013](../decisions/0013-in-cluster-client.md#findings)).
`ERL_FLAGS='+JMsingle true'` lets a prebuilt image's runtime start there, but
no recipe or manifest sets it: the committed Dockerfile does not build on that
host, no registry image exists yet, native amd64 needs no flag, and the flag
maps JIT code writable and executable at once instead of through two separate
mappings. On such a host the flag would go into the Deployment's existing
`ERL_FLAGS` value. An arm64 image, which ticket 38 prices, would need no
emulation.
`just image-check` and `just smoke` verify the Docker and kind paths separately. The image runs as UID/GID 10001. The Deployment
uses a read-only root filesystem, a writable temporary volume, dropped
capabilities, no privilege escalation and RuntimeDefault seccomp. The Role
grants `list` and `patch` on pods, bound to the `knarr` ServiceAccount by a
RoleBinding; token automount stays disabled, and a projected volume supplies a
600-second token, the cluster CA and the namespace to the S1 probe
([Decision 0013](../decisions/0013-in-cluster-client.md)). The Deployment
turns that probe on with `ERL_FLAGS=-knarr s1_probe true`; the gate's test
runs leave it off, so they make no API call. `just deploy <image> wrong-ca`
deploys the negative-TLS variant from `deploy/wrong-ca/`, which needs a
`knarr-wrong-ca` ConfigMap holding an unrelated `ca.crt`; the ticket 14
evidence script creates one from a throwaway certificate.

Before starting Erlang, the container entrypoint caps the soft file-descriptor
limit at 65,536, preserving any lower inherited limit. kind's containerd can
inherit a near-unlimited ceiling, which causes excessive descriptor-table
allocation before the application starts. The skeleton requests 64 MiB of
memory and has a 256 MiB limit; `just image-check` enforces that same limit with
swap disabled and verifies the descriptor cap. The printed memory reading is
informational, not a peak measurement or a capacity guarantee for future work.

The offline gate validates image lint, base resources against local Kubernetes
schemas, and static security settings. `just deployment-check`, with the
optional cluster tools installed, renders every variant under `deploy/`
(`base`, `release` and `wrong-ca`) with kustomize and validates each. It fails
unless the release overlay changes exactly two lines of the base's render: the
image, pinned by digest, and the pull policy. Container checks separately prove both image stages use
the pixi manifest's OTP major (with lock agreement checked by the gate) and that the runtime starts with a read-only root.
The kind smoke job proves actual endpoint access; the kwok job proves cluster
readiness only. Both jobs remain outside aggregate `check`.

The fake worker fixture has its own recipes on the same cluster:
`just fake-worker-image-build`, `just fake-worker-image-check`,
`just fake-worker-deploy` and `just fake-worker-smoke`. Its
[reference page](../reference/fake-worker.md) describes them.

After 14 consecutive days without infrastructure-related failures, a maintainer
may consider making kind required. That is a separate branch-protection decision,
not an automatic workflow change. See the [metrics decision](../decisions/0010-metrics.md)
and [testing reference](../reference/testing.md) for the other boundaries.
