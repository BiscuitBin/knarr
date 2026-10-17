# 52: Attach Observer to knarr on kind

**Context:** Nobody can inspect the running knarr node on the local kind cluster: its processes, supervision tree, ETS tables, memory or message queues. Erlang's built-in Observer does this, but it needs Erlang distribution, and nothing in the repository turns distribution on:

- No `-name`, cookie, epmd or `vm.args` exists. `ERL_FLAGS` carries only the `-knarr <key> <value>` application config (`deploy/base/resources.json`, read by `src/knarr/application_ffi.erl`).
- The image is an erlang-shipment on `ubuntu:24.04` with conda-forge OTP 29.1.1 (`Dockerfile`, [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md)).
- The pod runs with `readOnlyRootFilesystem` and drops every capability.
- There is no Service. Every local access goes through a loopback `kubectl port-forward` (`cluster.port_forward` in `scripts/checks/cluster.py`).

The host pixi environment (`.pixi/envs/default`) already ships `observer`, `wx` and `runtime_tools`. Nobody has checked that wx works on macOS.

The maintainer wants the GUI Observer on the Mac and a terminal fallback, observer_cli, both attached to knarr on kind and to nothing else. Distribution is remote code execution for anyone who holds the cookie, so it stays out of every shipped artefact.

**What to build:** a `deploy/observer/` overlay that turns distribution on, and three `[cluster]` recipes that attach to it. Work on the branch `52-local-observer`.

- **Step 0 spike.** Record the evidence in `.scratch/bootstrap/evidence/52/`, then decide each point:
  - **The wx GUI.** Run `.pixi/envs/default/bin/erl` and call `observer:start()` on macOS, and record the result. If wx fails, the fallback is a different OTP for the GUI side, which must share the pod's major version.
  - **Distribution without epmd.** The pod runs `-name knarr@127.0.0.1 -setcookie … -start_epmd false -erl_epmd_port <N>`, with `-kernel inet_dist_listen_min <N> inet_dist_listen_max <N> inet_dist_use_interface {127,0,0,1}`. Distribution then binds loopback inside the pod and is reachable only through a port-forward. The host node runs `-name observer@127.0.0.1 -hidden -dist_listen false -erl_epmd_port <N>`, which avoids any host epmd on 4369 and needs one forward. Record whether this works through `kubectl port-forward`. The alternative is forwarding epmd to a non-default local port with `ERL_EPMD_PORT`.
  - **Where the flags go.** Use `ERL_ZFLAGS` (or `ERL_AFLAGS`) so `ERL_FLAGS` keeps the `-knarr` application config. Read the shipment's `entrypoint.sh` (`build/erlang-shipment/`) to confirm `erl` reads them.
  - **The cookie.** `-setcookie` writes nothing to `$HOME`, which matters under `readOnlyRootFilesystem`. Decide between a dev-only literal and a per-cluster generated Secret fed through `$(VAR)` env substitution. Either way, mark it dev-only.
  - **Observer's needs on the target.** Confirm `runtime_tools` (`observer_backend`) survives `prune_runtime.py` in the runtime environment.
  - **observer_cli from a host node.** Find out whether it needs `observer_cli` or `recon` loaded on the target. If it does, decide whether to load them over distribution, so they never enter the image. Decide how the host gets observer_cli without adding it to `gleam.toml`; a hex download needs authorization. If neither works, record the fallback: `erl -remsh` with `i()` and `etop`.
- **The `deploy/observer/` overlay.** A `kustomization.yaml` and a `patch.json` that add only the distribution env and the container port, mirroring `deploy/e2e-fast`. `deployment.variants()` in `scripts/checks/deployment.py` discovers it on its own, and the list `test_deployment.py` pins gains `observer`. The deployment tests also gain an assertion that it renders the distribution flags, and another that `deploy/base` and `deploy/release` carry none.
- **The `[cluster]` recipes.** All three are kind-only, like ticket 51's, and join `KIND_ONLY` in `cluster.py`:
  - `just observer` forwards the distribution port with `cluster.port_forward` and starts a local hidden node that connects to `knarr@127.0.0.1` and calls `observer:start()`.
  - `just observer-cli` does the same for observer_cli.
  - `just remsh` is the fallback.
  - None of them runs in `just check`. Offline tests in `scripts/checks/tests/` pin the argv, the kwok refusal and the overlay.
- **Docs.**
  - The how-to page `docs/how-to/local-observer.md`, registered in `docs/manifest.yml` and reachable from `docs/README.md`.
  - An amendment to [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md) or [0013](../../../docs/decisions/0013-in-cluster-client.md): distribution is dev-only, because a cookie grants remote code execution.
  - `CHANGELOG.md`.
  - If any recipe reaches the network, AGENTS.md's network list and CONTRIBUTING.md, checked with `just agents-check`.

**Non-goals:**

- Distribution in `deploy/base`, `deploy/release`, the image or the future Helm chart.
- Attaching on any cluster other than this worktree's kind cluster.
- CI or `just check` wiring.
- Adding observer_cli or recon to `gleam.toml` or to the image.
- TLS distribution.

**Blocked by:** 29, 50

**MVP critical path:** no. It is a contributor convenience.

**Status:** ready-for-agent

- [ ] **Authorization required:** Step 0 on this worktree's kind cluster, and any hex download it needs. The decisions are recorded in the evidence.
- [ ] `deploy/observer/` holds the overlay. Its deployment tests, and the assertion that the base and release carry no distribution flags, were seen failing first.
- [ ] The `observer`, `observer-cli` and `remsh` recipes exist, kwok refuses all three, and their offline tests were seen failing first.
- [ ] The how-to page and its registration, the decision amendment and `CHANGELOG.md` carry the change, and AGENTS.md too if a recipe reaches the network.
- [ ] **Authorization required:** the live attach on this worktree's kind cluster, with the GUI Observer and observer_cli (or `remsh`, if Step 0 chose it).
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."
- [ ] **Authorization required:** a push and a pull request.

## Hand-back notes
