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
The image builds for the host architecture, so on an Apple-silicon host it is
a native linux/arm64 image for the arm64 kind node;
[Image and checks](#image-and-checks) says what differs from the release.
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
copied at its original absolute prefix. `just image-build` and
`just fake-worker-image-build` build for the host architecture: linux/amd64 on
an x86_64 host, as in CI, and linux/arm64 on an Apple-silicon host, from the
lock's `linux-aarch64` entries. Pass a platform as the second argument to
override it, as in `just image-build knarr:local linux/amd64`, but an amd64
image does not build or run under Rosetta: OTP 29's amd64 BEAM fails there in
`prim_tty`. `just image-check` runs the image at its own architecture. The
release image is linux/amd64 only and is built in CI
([Decision 0012](../decisions/0012-release-and-packaging.md)).
`just image-check` and `just smoke` verify the Docker and kind paths separately. The image runs as UID/GID 10001. The Deployment
uses a read-only root filesystem, a writable temporary volume, dropped
capabilities, no privilege escalation and RuntimeDefault seccomp. The Role
grants `list` and `patch` on pods, `list` on Deployments and ReplicaSets and
`create` on events, the verbs the `Verbs` clause of
[k8s_client.allium](../specs/k8s_client.allium) names, bound to the `knarr`
ServiceAccount by a RoleBinding; token automount stays disabled, and a projected volume supplies a
600-second token, the cluster CA and the namespace to the reconciler
([Decision 0013](../decisions/0013-in-cluster-client.md)). The Deployment
turns discovery on with `ERL_FLAGS=-knarr discovery true`; the gate's test
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
(`base`, `e2e-fast`, `release` and `wrong-ca`) with kustomize and validates each. It fails
unless the release overlay changes exactly two lines of the base's render: the
image, pinned by digest, and the pull policy. Container checks separately prove both image stages use
the pixi manifest's OTP major (with lock agreement checked by the gate) and that the runtime starts with a read-only root.
The kind smoke job proves actual endpoint access; the kwok job proves cluster
readiness only. Both jobs remain outside aggregate `check`.

The fake worker fixture has its own recipes on the same cluster:
`just fake-worker-image-build`, `just fake-worker-image-check`,
`just fake-worker-deploy` and `just fake-worker-smoke`. Its
[reference page](../reference/fake-worker.md) describes them. `just keda-e2e`
runs [the KEDA end-to-end harness](../reference/keda-e2e.md) on the same cluster
after both images are built.

After 14 consecutive days without infrastructure-related failures, a maintainer
may consider making kind required. That is a separate branch-protection decision,
not an automatic workflow change. See the [metrics decision](../decisions/0010-metrics.md)
and [testing reference](../reference/testing.md) for the other boundaries.
