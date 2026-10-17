# 52: Opt-in Voyager inspection of knarr on the local kind cluster

**Context:** The maintainer uses the Voyager desktop app (Software Mansion) on macOS and wants it to show the knarr controller running on the worktree's kind cluster. Voyager attaches as a hidden node over standard Erlang distribution, so it needs no hex dependency and no Gleam change. The shipment runs `erl … -noshell` with no `-name`, so knarr is not distributed. Using Voyager must be optional and opt-in: the image, `deploy/base/`, `deploy/release/`, `just check` and `just keda-e2e` stay as they are. The maintainer chose to support both Voyager 0.1.0, which was installed, and 0.2.0-rc.1, which adds processes and ETS. They also chose a `deploy/voyager/` overlay with `cluster`-group recipes and a random cookie per worktree, injected through a Secret created imperatively. The record is this ticket and a how-to page: no decision record and no Allium clause.

**What to build:** A `deploy/voyager/` kustomize variant that turns on long-name distribution as `knarr@127.0.0.1`, with epmd and the distribution listener on fixed ports bound to loopback in the pod. `cluster.py deploy` writes the cookie and applies the `knarr-voyager` Secret for that variant only. A `voyager-forward` action forwards both ports, probes the node and prints the Connect details. `just voyager-deploy` and `just voyager-forward` call them. Checker tests cover all of it, and [the how-to page](../../../docs/how-to/voyager.md) states the exceptions.

**Non-goals:** Production or release support. Any image, entrypoint or Gleam change. A Secret rendered by kustomize, since no Secret schema is vendored and kubeconform runs `-strict`. Running two worktrees' forwards at once.

**Blocked by:** 34, 50

**MVP critical path:** no. This is a maintainer's inspection aid.

**Status:** done.

- [x] The spike on this worktree's kind cluster answers whether port-forward dials `127.0.0.1` or `::1` in the pod, whether epmd starts as uid 10001 on the read-only root, and whether `{127,0,0,1}` survives `ERL_FLAGS`. `compiler` is in the image.
- [x] `deploy/voyager/` patches only container `knarr`: `ERL_FLAGS` with discovery kept, `ERL_ZFLAGS` from the Secret, `ERL_EPMD_ADDRESS`, `HOME` and two documentation-only ports. `just deployment-check` renders and validates all five variants, and the release overlay still differs from the base in its two lines.
- [x] Only the voyager deploy writes `.cluster/voyager-cookie` (0600, 64 hex digits) and applies the Secret, before the variant. `voyager-forward` refuses kwok, a taken port and a Deployment without distribution.
- [x] Checker tests were written first and failed, then passed.
- [x] Live on 0.1.0: the overview and supervision trees render.
- [x] **Authorization required:** the maintainer installs 0.2.0-rc.1 (network and desktop app). The process list and ETS pages render.
- [x] Opt-out: `just deploy` returns to the base, and `just smoke` passes.
- [x] The how-to page, the local-cluster how-to, the docs index and the bootstrap graph carry the change.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

Done on 2026-10-16.

**Authorization lapse.** The spike ran `just cluster-up`, which may download images, and `just image-build`, which reaches the network. Both ran on the plan's line that the spike was "local, so no authorization is needed", and neither was authorized separately. Codex's first review flagged this after both had run. The maintainer installed 0.2.0-rc.1 themselves.

### Spike answers

Answers recorded with the trial environment set by `kubectl set env` on the base:

- **(a) The port-forward dials IPv4 loopback.** With the distribution listener bound only to `127.0.0.1:9100`, `erl_call -name knarr@127.0.0.1` through `kubectl port-forward --address=127.0.0.1 deployment/knarr 4369:4369 9100:9100` printed `'knarr@127.0.0.1'`. No fallback to all interfaces was needed.
- **(b) epmd starts.** `epmd -daemon` ran as uid 10001 with the read-only root. `/proc/net/tcp` showed epmd on `127.0.0.1:4369` and `::1:4369`, and `epmd -names` listed `knarr at port 9100`.
- **(c) The tuple survives.** `-kernel inet_dist_use_interface {127,0,0,1}` in `ERL_FLAGS` needed no quoting. The listener bound `0100007F:238C`, which is 127.0.0.1:9100, only.
- **compiler** is in the runtime as `compiler-10.0.6`, beside `runtime_tools-2.5`.
- **The reset needed care.** `just deploy` did not remove the env that `kubectl set env` added: a client-side apply keeps fields it never recorded. `kubectl set env … ERL_ZFLAGS- ERL_EPMD_ADDRESS- HOME-` removed them. The overlay-to-base path is different, because apply recorded the variant's fields, and it was verified separately (below).

### What changed

- `deploy/voyager/kustomization.yaml` and `patch.json`. The kustomization holds the base and the patch only.
- `scripts/checks/cluster.py`:
  - `voyager_cookie()` writes a private temporary file and links it into place, keeping a cookie another caller published first. It refuses a symlink, a file that group or others can read, or content that is not 64 hex digits. The cookie is hex because one beginning with `-` would read as another erl flag.
  - `deploy()` applies the Secret first for `variant == "voyager"`.
  - `taken_ports()` probes by connecting.
  - `probe_node()` bounds each `erl_call`.
  - `voyager_forward()`.
  - The constants `VOYAGER_PORTS`, `VOYAGER_NODE`, `ERL_CALL` and `PROBE_SECONDS`. The Secret's name is inlined, because ruff's S105 reads a constant named `*SECRET` as a password.
- `Justfile`: `voyager-deploy` and `voyager-forward` in the `cluster` group. No other recipe calls them.
- Tests:
  - `test_deployment.py`: the voyager patch's whole shape, its kustomization lines, the variant list, and five renders.
  - `test_cluster_commands.py`: Secret content and order, no Secret for the base, cookie mode and reuse, refusals of a loose, empty, non-hex or symlinked cookie, the publish race, kwok, a taken port, a free but held port, the fixed-port command, a stalled probe, and a Deployment without distribution.
- Docs: `docs/how-to/voyager.md`, which is new, plus `docs/manifest.yml`, `docs/README.md`, `docs/how-to/local-cluster.md` and `.scratch/bootstrap/README.md`.

### What was verified

- The checker tests failed first and then passed: 51 passed in `test_cluster_commands.py` and `test_deployment.py`.
- `just deployment-check` rendered and validated base, e2e-fast, release, voyager and wrong-ca, and printed "release overlay: image …, imagePullPolicy IfNotPresent, nothing else".
- **`just voyager-deploy` and `just voyager-forward`** were run live:
  - The cookie file is `-rw-------`.
  - The Deployment's env carries `ERL_ZFLAGS` only as a `secretKeyRef`.
  - The forward printed `ok erl_call: 'knarr@127.0.0.1'` and the Connect details.
  - In the pod, the beam command line shows `-setcookie <cookie>`.
- **Voyager 0.1.0**, checked by the maintainer:
  - It connected with long names, and the supervision tree showed knarr's application.
  - Selecting `mist` showed an error. mist's application master's child is `mist@internal@clock`, a Gleam actor in `gleam_erlang_ffi:select/2`, not a supervisor. That is upstream mist and Voyager behaviour, not knarr's.
  - The pod's epmd listed only `knarr`, so 0.1.0 registered nothing with it. Voyager attached as the hidden node `voyager@127.0.0.1`.
- **Voyager 0.2.0-rc.1:**
  - The maintainer saw the Processes and ETS pages render.
  - The MCP endpoint at `127.0.0.1:4040/mcp` reported `serverInfo` version `0.2.0-rc.1`. `node_info` showed `knarr@127.0.0.1` on OTP 29, erts 17.1, aarch64. `process_list` included `knarr_reconciler$2245`, and `ets_list` reported 49 tables.
  - `voyager_agent_bab57f1e700b` was loaded on the node, with no resident agent process between requests.
  - Node memory was 52.8 MB, and the pod had 0 restarts on the 256 Mi limit, which stays unchanged.
- **Opt-out and recovery:**
  - SIGINT ended `voyager-forward` with no traceback and freed both ports.
  - `just deploy` left `ERL_FLAGS=-knarr discovery true` and only port 8080, and `just smoke` reported ok for `/healthz`, `/readyz` and `/metrics`.
  - After `kubectl rollout restart`, the forward stayed bound until the next connection. kubectl then logged `lost connection to pod`, and `voyager-forward` exited with `port-forward ended (1)`.
- **The bind probe gave a false refusal.** The first redeploy check refused with "127.0.0.1:9100 already in use" while nothing listened. The likely cause is the stopped forward's TIME_WAIT connections, which fail a plain macOS bind, though the TIME_WAIT state was gone before it could be observed. The probe now connects instead, and the retry got through.
- **Back-to-back probes collided.** Two `erl_call`s started within about 10 ms: the second failed to connect. Spaced a second apart, every one answered.
- A blocking `supervisor:which_children` that I sent to the clock actor while diagnosing mist left one eval process waiting on the node. The opt-out redeploy replaced the pod.

### Codex reviews (gpt-6-astra, static)

1. **The plan** (the report stays in `ai_tmp/`, uncommitted): four findings.
   - Spike kubectl was not scoped to the worktree: addressed, since every command ran with `KUBECONFIG=.cluster/kubeconfig`.
   - An imperative env survives `just deploy`: confirmed and addressed, as above.
   - The probe could run before rollout: addressed by waiting on `rollout status`; the forward's probe retries for 30 s.
   - Network actions without authorization: confirmed after the fact. See the authorization lapse above.
2. **The code diff:** six findings, all addressed.
   - `erl_call` had no time bound: `probe_node` now passes a timeout and checks the forward.
   - A loose or malformed cookie file was accepted: it is now validated.
   - Cookie creation was not atomic: it now writes a temporary file and links it.
   - Ctrl-C during startup gave a traceback: the forward's lifecycle catches it and returns, and review 3 found the steps before the forward still could, so `main` now exits 130 on `KeyboardInterrupt`.
   - The Secret test passed with an empty payload: the fake now emits a document, and the test checks apply's stdin.
   - The patch test checked only the pod spec: it now checks the whole patch.
   - Codex reported no finding on flag quoting, merge keys, kubeconform, opt-in isolation and the erl_call path.
3. **Docs and hand-back notes:** five findings, all addressed.
   - Claims beyond what was observed: the how-to says knarr's tree rendered, not every tree, drops "loads nothing" for 0.1.0, and qualifies the 0.2.0-rc.1 agent's processes.
   - "Every deploy" replaces the pod: narrowed to a rollout that replaces it.
   - Unsourced or documented-not-observed claims: the license, the IP-literal parser and the error names are attributed to Voyager's documentation, the probe collision is stated as observed, and "only port-forward" is narrowed.
   - Ctrl-C before the forward: fixed in `main`, as above.
   - Codex reported no finding on implementation alignment, prior-review accounting, protected paths, gate and KEDA isolation, and the docs contract.

4. **Adversarial review (Codex, `gpt-6-astra`):** two findings, both addressed.
   - The cookie sat in host process arguments (`erl_call -c` and `kubectl --from-literal`): the Secret now goes to `kubectl apply` on stdin, and the probe gives `erl_call` a private `HOME` holding `.erlang.cookie`. Against a local node, `erl_call` with that `HOME` answered, and without it failed with `can't open cookie file`.
   - SIGTERM skipped the forward's cleanup and left `kubectl port-forward` holding the ports: `main` now turns SIGTERM into an exit, so the `finally` stops kubectl. A subprocess test signals the wrapper and checks kubectl is gone.

### What later tickets need

- **Nothing on the critical path.** 0.2.0 is a pre-release, so recheck when 0.2.0 is final: the agent module and its unsupervised processes may change.
- The Voyager error names on the how-to page (`node_not_registered`, `bad_cookie`, `name_type_mismatch`) come from Voyager's connection documentation. This run reproduced none of them.
- **OTP skew.** Voyager 0.1.0 bundles OTP 29.0.x, and knarr runs 29.1.1 (erts 17.1). No incompatibility showed.
