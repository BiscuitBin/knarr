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

**Status:** done, except the GUI Observer window, which needs a wx-capable OTP 29 on the host. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** Step 0 on this worktree's kind cluster, and the hex download of observer_cli and recon, which the maintainer authorized on 2026-10-17. The decisions are recorded in [the evidence](../evidence/52/README.md).
- [x] `deploy/observer/` holds the overlay. Its deployment tests, and the assertion that the base and release carry no distribution flags, were seen failing first.
- [x] The `observer`, `observer-cli` and `remsh` recipes exist, with `observer-cli-install` beside them, kwok refuses the three that attach (the install needs no cluster), and their offline tests were seen failing first.
- [x] The how-to page and its registration, the decision amendment and `CHANGELOG.md` carry the change, and AGENTS.md and CONTRIBUTING.md too, since `observer-cli-install` reaches the network.
- [ ] **Authorization required:** the live attach on this worktree's kind cluster, with the GUI Observer and observer_cli (or `remsh`, if Step 0 chose it). observer_cli and `remsh` attached live on 2026-10-17. The GUI window is unverified: no wx-capable OTP 29 was installed on the host, so `just observer` was seen only refusing the pixi `erl` for its missing wx driver.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."
- [ ] **Authorization required:** a push and a pull request.

## Hand-back notes

Done on 2026-10-17, apart from the GUI window. The maintainer authorized four things that day: the kind cluster and image build, the hex download of observer_cli and recon, the local branch rename to `52-local-observer`, and a dev-only literal cookie. Evidence: [evidence/52](../evidence/52/README.md).

### What changed

- **`deploy/observer/`:** a kustomization over `../base` and a strategic-merge `patch.json`. The patch adds `ERL_ZFLAGS` (`-name knarr@127.0.0.1 -setcookie knarr-dev-only -start_epmd false -erl_epmd_port 4370`, with `inet_dist_listen_min`/`max` 4370 and `inet_dist_use_interface {127,0,0,1}`) and the container port `erlang-dist` 4370. The base's `ERL_FLAGS` and `http` port survive the merge. `deployment.variants()` finds the overlay on its own.
- **`scripts/checks/tests/test_deployment.py`:**
  - The variants list gains `observer`, and the overlay's patch is pinned exactly.
  - Every file under `deploy/base` and `deploy/release` is refused if it names `ERL_ZFLAGS`, `ERL_AFLAGS`, `-setcookie`, `-name`, `-sname` or `4370`, each as a whole token, so a digest holding the digits 4370 or a key such as `secret-name` does not match.
  - The fake-kustomize render tests count five variants.
- **`scripts/checks/observer.py`:**
  - It reads the node, cookie and port from the overlay.
  - Pure argv builders for the host node (`-name observer-<pid>@127.0.0.1 -hidden -start_epmd false -dist_listen false -erl_epmd_port <forwarded port>`), the GUI (`observer:start_and_wait/1`), observer_cli and `-remsh`.
  - `check_erl` reads the probe's last line and refuses an OTP major other than 29, an answer it cannot read, or a GUI `erl` whose wx has no driver.
  - `install` needs no cluster. It creates `.cluster/` with mode 0700 when it is missing, as `cluster-up` does, since the kubeconfig lands there later. It fetches the hex tarballs that `fixtures/observer/packages.json` pins through `keda_e2e.fetch_pinned` (sha256, cached, written atomically), extracts `contents.tar.gz` with tarfile's `data` filter, and compiles both with `erlc` into `.cluster/observer/ebin/`. It replaces the previous ebin only once everything has compiled.
  - The observer_cli session lists the ebin with `filelib:wildcard("*.beam", Dir)`, so the path is literal, not a pattern. It purges, loads every module onto knarr with `code:load_binary`, runs observer_cli, then deletes and purges them in an `after` clause. It exits 0 only on observer_cli's `quit`.
  - For the three attach actions, `main` calls `cluster.environment` (so kwok is refused first), forwards `deployment/knarr` on 4370, and runs the node in the foreground. Ctrl-C, while the forward starts or the node runs, exits 0.
- **`keda_e2e.py` and `observability.py`:** the pinned, cached, atomic download moves into `keda_e2e.fetch_pinned`, beside `verify_download`. `observability.fetch_chart` and `observer.fetch` both call it.
- **`cluster.py`:** the three attach actions join `KIND_ONLY`.
- **The Justfile:** `observer [erl]` (default `KNARR_OBSERVER_ERL`), `observer-cli-install`, `observer-cli` and `remsh`, all `[group('cluster')]` and none in `check`.
- **The checker suite:** the `cluster` group owns `test_observer`, `scripts/checks/observer.py` and `fixtures/observer/**`.
- **Renovate:** `observer_cli` and `recon` are `enabled: false`.
- **Docs:**
  - The how-to `docs/how-to/local-observer.md`, registered and linked from the index.
  - A ticket 52 amendment under Decision 0012 §9.15: distribution is dev-only.
  - `CHANGELOG.md`, and the network lists in AGENTS.md and CONTRIBUTING.md.

### Departures from the plan

- **The host node also passes `-start_epmd false`.** Without it, the spike left the pixi `epmd -daemon` running even with `-dist_listen false`.
- **The shipped-variant guard reads the source files,** not real renders. kustomize is only on the `cluster` environment's PATH, and the deployment tests fake it. `just deployment-check` renders and validates the observer variant for real, and the live deploy shows the merged env.
- **observer_cli 2.0.0 and recon 2.5.6,** the newest releases, both more than two weeks old.
- **The entrypoint was read from the image.** `gleam export erlang-shipment` needs `rebar3`, which the host's default environment lacks.

### Corrections after code review

The `code-review` skill, at high effort, reported nine findings. Each fix below was seen failing first against the pre-review module, as [red-observer.txt](../evidence/52/red-observer.txt) records.

- **Two sessions collided:** every host node was `observer@127.0.0.1`, and knarr holds one connection per name. The name is now `observer-<pid>`, and [live-two-sessions.txt](../evidence/52/live-two-sessions.txt) shows observer_cli and `remsh` attached at once.
- **A failed observer_cli exited 0.** It now exits 1 unless observer_cli returns `quit`.
- **The guard matched substrings,** so a release digest holding `4370` would have failed `just check`. It now matches whole tokens.
- **`observer-cli-install` demanded a kind cluster.** It no longer does, and leaves `KIND_ONLY`.
- **Ctrl-C while the forward started printed a traceback.** It is now a clean stop. Not fixed: Ctrl-C also stops `kubectl port-forward`, so an observer_cli session ended that way leaves its modules on knarr until the next session or a pod restart. The how-to says so.
- **Glob metacharacters in the checkout path** would have matched no beams; the path is now literal.
- **`fetch` duplicated `observability.fetch_chart`;** both now call `keda_e2e.fetch_pinned`.
- **`check_erl` crashed on an unexpected answer;** it now names the how-to.
- **The how-to said four recipes attach;** three do.

### Verified

- Focused: `test_deployment.py`, `test_observer.py`, `test_checker_suite.py`, `test_dependency_pins.py`, `test_observability.py` and `test_cluster_commands.py` pass. So do `just deployment-check`, `just docs-check` and `just agents-check`.
- Live on kind:
  - the port-forward attach;
  - `just observer-cli-install`, also under `KNARR_CLUSTER=kwok`;
  - `just observer-cli`;
  - `just remsh` with `i()`, after which observer_cli and recon were no longer loaded;
  - observer_cli and `remsh` attached at once;
  - `just observer`'s two refusals;
  - `just smoke` on the observer variant.
- `just check`, as the box above records.

### Not verified

- **The GUI Observer window.** With a wx-capable OTP 29 installed (for example `brew install erlang`, checked as the how-to shows), run `just deploy <image> observer` and `just observer /opt/homebrew/bin/erl`, and confirm the window opens on `knarr@127.0.0.1`. That a Homebrew formula currently ships OTP 29 with wx was not checked.
- Interactive use in a real terminal. The live runs fed stdin from a pipe. In a terminal, Ctrl-C reaches both erl and the Python wrapper, which then stops the session.

### What later tickets need

- **The Helm chart tickets:** a chart must never carry distribution, a cookie or port 4370. Decision 0012's amendment and `test_shipped_variants_carry_no_distribution` state the rule; extend the test to the chart's render when it lands.
- **Moving observer_cli or recon:** a hand edit of `fixtures/observer/packages.json` (version, URL and sha256 together), then `just observer-cli-install` and `just observer-cli`.
