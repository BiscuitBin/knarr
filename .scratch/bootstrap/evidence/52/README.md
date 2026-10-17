# Ticket 52 evidence

The spike, decisions and live attach for [ticket 52](../../issues/52-local-observer.md), Observer on knarr on kind. [The how-to](../../../../docs/how-to/local-observer.md) describes the recipes.

**Status:** run on 2026-10-17 (local time) on the maintainer's Apple-silicon host, Darwin arm64, with OrbStack's Docker engine (linux/arm64). The cluster was this worktree's kind cluster, kind v0.33.0 on node image v1.35.8, and the image was `just image-build`'s native arm64 build. The maintainer authorized the kind cluster, the image build and the hex download of observer_cli and recon.

## Decisions (Step 0)

### The wx GUI: a user-installed OTP 29

[wx.txt](wx.txt): `.pixi/envs/default/lib/erlang/lib/wx-2.7` has `doc`, `ebin`, `include` and `src`, but no `priv/` and no `wxe_driver`. `observer:start()` crashes in `wxe_master:init/1` with `{load_driver,"No driver found"}`. There was no other `erl` on the host.

Decision: the GUI side takes its `erl` from outside the repository. `just observer <erl>`, or `KNARR_OBSERVER_ERL`, names it. `check_erl` refuses an `erl` whose `otp_release` is not the pod's `29`, or whose `code:priv_dir(wx)` has no `wxe_driver*`. The how-to points to `brew install erlang` and a one-line check. observer_cli and `remsh` need no wx, so they use the pixi `erl`.

The GUI argv, `observer:start_and_wait('knarr@127.0.0.1')`, rests on observer 2.19's source (`lib/observer-2.19/src/observer.erl`): `start_and_wait(Node) when is_atom(Node)` calls `start([Node])`, which runs `net_kernel:connect_node(Node1)`, starts `observer_wx` and calls `observer_wx:set_node(Node1)`, then waits for the `observer` process to go down. From a `-hidden` node the connection is hidden, and the GUI opens on knarr rather than relying on the Nodes menu.

### Distribution without epmd: one forward

[dist-spike.txt](dist-spike.txt) runs two `.pixi` nodes on loopback. The "pod" has the overlay's exact flags, and the host has `-name observer@127.0.0.1 -hidden -start_epmd false -dist_listen false -erl_epmd_port 4370 -setcookie knarr-dev-only`. The results:

- The pod node listens on `127.0.0.1:4370` only.
- `net_adm:ping` answers `pong`, the pod sees the host in `nodes(hidden)`, and `observer_backend` resolves on the target.
- A wrong cookie gives `pang`.
- `-remsh` gives a `(knarr@127.0.0.1)1>` prompt.
- `pgrep epmd` finds nothing before or after.

The host needs `-start_epmd false` as well. A first run without it left the `.pixi` `epmd -daemon` running even with `-dist_listen false`, so that daemon was killed and the evidence rerun.

[port-forward.txt](port-forward.txt) repeats this on kind. `just deploy <image> observer` was followed by `kubectl port-forward --address=127.0.0.1 deployment/knarr :4370`, and the host node was given the *forwarded* local port as `-erl_epmd_port`. It got `pong`, OTP `29`, `observer_backend` from the image's runtime environment, knarr's applications, 120 processes and 0 restarts, and no epmd on the host.

Decision: as the ticket proposed. The pod runs `-start_epmd false -erl_epmd_port 4370` with `inet_dist_listen_min`/`max` 4370 and `inet_dist_use_interface {127,0,0,1}`. One forward is enough, and no host port is fixed: the OS picks the local one, as Decision 0007 has it. The `ERL_EPMD_PORT` fallback was not needed.

### Where the flags go: `ERL_ZFLAGS`

[entrypoint.txt](entrypoint.txt): the shipment's `entrypoint.sh`, read from the built image, runs `exec erl -pa … -eval "knarr@@main:run(knarr)" -noshell -extra "$@"`, so `erl` reads `ERL_ZFLAGS` (and `ERL_AFLAGS`). `gleam export erlang-shipment` could not run on the host (no `rebar3` on the default environment's PATH), so the file was read from the image instead. The rendered Deployment carries both `ERL_ZFLAGS` and the base's unchanged `ERL_FLAGS`. Strategic merge keys env by name and ports by `containerPort`, and the pod started with both (port-forward.txt and `just deployment-check`).

### The cookie: a dev-only literal

`-setcookie` writes nothing to `$HOME`, so `readOnlyRootFilesystem` is no obstacle. The maintainer chose a literal, `knarr-dev-only`, over a generated Secret. It is published in the overlay and the how-to and is not a secret. The overlay's comment and the how-to say why it is dev-only: a cookie grants remote code execution. `observer.py` reads the node, cookie and port from `deploy/observer/patch.json`, so they have one source.

### Observer's needs on the target: `runtime_tools` survives

[runtime-tools.txt](runtime-tools.txt): the pruned runtime environment in the image keeps `runtime_tools-2.5` with `observer_backend.beam`. `prune_runtime.py` is called with `perl` only. The live attach then resolves `observer_backend` on the pod.

### observer_cli from a host node: loaded over distribution for the session

[observer-cli.txt](observer-cli.txt), on a freshly restarted pod:

- `observer_cli.erl`'s `rpc_start/2` connects and then makes `rpc:call(Node, observer_cli, start, [Interval])`, so its UI runs on the target.
- With the modules only on the host, `observer_cli:start('knarr@127.0.0.1', 'knarr-dev-only')` returns `{badrpc,{'EXIT',{undef,[{observer_cli,start,[1500],[]}]}}}`.
- Loading all 31 modules (observer_cli 2.0.0 and recon 2.5.6, which it requires) onto the target with `code:get_object_code/1` and `rpc:call(N, code, load_binary, [M, F, B])` gives the full home screen. After `q`, purge, delete and purge leave none of them loaded.

An earlier run had shown that `load_binary` and `code:delete` refuse while old code is still present. That is why the session purges before each load and after each delete.

Decision: `just observer-cli-install` downloads the hex tarballs that `fixtures/observer/packages.json` pins. Each tarball's sha256 equals hex's published outer checksum. The install extracts `contents.tar.gz` with tarfile's `data` filter and compiles both packages with the pixi `erlc` (same OTP as the pod) into `.cluster/observer/ebin/`. `just observer-cli` loads the modules into the pod's memory only, and an `after` clause removes them. Nothing enters `gleam.toml` or the image. The `remsh` fallback exists as well.

## Tests seen failing first

- [red-deployment.txt](red-deployment.txt): the overlay's tests before `deploy/observer/` existed, and the shipped-variant guard parametrized once over `deploy/observer` to show it can fail.
- [red-observer.txt](red-observer.txt): `test_observer.py` against a skeleton whose functions raise `NotImplementedError`, the checker-suite ownership and selection cases before `observer` joined the `cluster` group, and the tests revised after the code review against the pre-review module.
- [red-copilot.txt](red-copilot.txt): the tests for the two Copilot findings on the pull request against the reviewed module: two forwards to one target shared a log, and a second observer_cli session loaded over the first.

## Live attach

- [live-install.txt](live-install.txt): `just observer-cli-install` compiled 31 modules, the cached tarballs hash to the pins, and it also runs under `KNARR_CLUSTER=kwok`, since it needs no cluster.
- [live-observer-cli.txt](live-observer-cli.txt): `just observer-cli` showed knarr's home screen (OTP 29, `knarr@127.0.0.1`, its processes), quit on `q`, and exited with 0.
- [live-remsh.txt](live-remsh.txt): `just remsh` ran `i()`. `code:is_loaded(observer_cli)` and `code:is_loaded(recon)` were both `false` after the observer_cli session. EOF left the shell, and knarr kept running with 0 restarts. `i()` pages, so a scripted run must answer its `more (y/n)?` prompt. A first scripted run hung there and was killed. The middle of the `i()` listing is elided, because its fixed-width columns truncate names that the typos check reads as misspellings.
- [live-two-sessions.txt](live-two-sessions.txt): observer_cli and `remsh` attached at once, as `observer-<pid>` nodes knarr lists in `nodes(hidden)`. observer_cli's modules were loaded during its session and gone after it.
- [live-two-observer-cli.txt](live-two-observer-cli.txt): a second `just observer-cli` refused while one was attached, naming it, and the first kept running. A session started as soon as a Ctrl-C ended another attached, so knarr drops the dead session's node at once.
- [live-observer.txt](live-observer.txt): `just observer` with no `erl` names the how-to, and with the pixi `erl` it refuses for the missing wx driver. **The GUI window itself is unverified:** no wx-capable OTP 29 was installed on the host during this run.
- [live-smoke.txt](live-smoke.txt): `just smoke` passes on the observer variant.

[remsh-q.txt](remsh-q.txt): `q()` in a remote shell stops the *remote* node, because the shell evaluates there. The local node is then left running with no shell. The how-to and the recipe's description say to leave with Ctrl-G then `q`.
