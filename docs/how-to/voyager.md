---
title: "Inspect knarr with Voyager on the local cluster"
kind: "how-to"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["voyager_inspection"]
requires: []
---

# Inspect knarr with Voyager on the local cluster

[Voyager](https://github.com/software-mansion/voyager) is a desktop app from Software Mansion that shows a running BEAM node: its overview, supervision trees and, from 0.2.0-rc.1, its processes and ETS tables. It attaches as a hidden node over standard Erlang distribution, so knarr needs no dependency and no code change. knarr does not run distributed by default. The opt-in `voyager` variant under `deploy/` turns distribution on, for this worktree's kind cluster only ([ticket 51](../../.scratch/bootstrap/issues/51-voyager-viz.md)).

Nothing else uses the variant. The image, `deploy/base/`, `deploy/release/`, `just check` and `just keda-e2e` are unchanged.

## Prerequisites

- The worktree's kind cluster and image: `just cluster-up` and `just image-build`, as in [Run the walking skeleton locally](local-cluster.md).
- Voyager 0.1.0 or 0.2.0-rc.1 on the host; both were checked against knarr. Voyager has its own license, the Voyager User License, which, per Voyager's repository at the time of writing, is free for organisations of up to ten people. Check the current terms before you install it.

## Connect

1. Run `just voyager-deploy`. The first run writes a random 64-digit hex cookie to `.cluster/voyager-cookie`, readable only by its owner. Each run applies it as the Secret `knarr-voyager`, then rolls out the variant. `just deploy <image> voyager` does the same.
2. Run `just voyager-forward` and leave it running. It forwards host `127.0.0.1:4369` (epmd) and `127.0.0.1:9100` (distribution) to the same ports in the pod. It proves the node answers through `erl_call`, prints the connection details, and holds the forward until Ctrl-C.
3. In Voyager's Connect form, enter:
   - **Node:** `knarr@127.0.0.1`
   - **Name type:** long names
   - **Cookie:** the value `voyager-forward` printed, also in `.cluster/voyager-cookie`

The node name's host part is the literal `127.0.0.1`. Voyager's connection guide says its connector parses IP literals, and the distribution handshake checks the name.

To probe by hand while the forward runs, use the repository's OTP: `.pixi/envs/default/lib/erlang/bin/erl_call -name knarr@127.0.0.1 -c "$(cat .cluster/voyager-cookie)" -a 'erlang node'` prints `'knarr@127.0.0.1'`. `-c` puts the cookie in the host's process list for as long as the probe runs; `just voyager-forward` avoids that by giving `erl_call` a private `HOME` holding `.erlang.cookie`. `erl_call` is not on the recipes' `PATH`. Space repeated probes about a second apart: two started within milliseconds of each other failed, and spaced probes all answered.

## What each version shows

- **0.1.0:** the node overview and supervision trees. knarr's application tree renders. Selecting the `mist` application shows an error: mist's application callback starts a plain actor (`mist@internal@clock`), not a supervisor, so there is no tree to draw. While attached, 0.1.0 registered no name with the pod's epmd.
- **0.2.0-rc.1:** adds the process list and ETS tables. Attaching loads a module, `voyager_agent_<hash>`, onto knarr's node. No agent process stayed resident between requests; whatever it runs during a request is started over distribution, outside knarr's supervision tree. Its MCP endpoint at `http://127.0.0.1:4040/mcp` answers `node_info`, `process_list` and `ets_list` for knarr. On the 256 MiB limit, the node used about 52 MB with 0.2.0-rc.1 attached, and the pod did not restart.

## Troubleshooting

The first three error names come from Voyager's connection guide; ticket 51 reproduced only the port and forward cases.

- **`node_not_registered`:** Voyager reached an epmd that does not know `knarr`. Either the forward is down, or a local epmd answered on 4369 instead. Restart `just voyager-forward`.
- **`bad_cookie`:** the cookie does not match. Copy it again from `.cluster/voyager-cookie`. If that file was deleted, `just voyager-deploy` writes a new cookie into the Secret, but the pod reads the Secret only when it starts. Restart it with `kubectl --kubeconfig .cluster/kubeconfig rollout restart deployment/knarr`.
- **`name_type_mismatch`:** select long names, not short names.
- **"something already listens on 127.0.0.1:4369":** a local epmd, usually left by an `erl -sname` or `erl -name` session, holds the port. Stop it with `epmd -kill`, then rerun `just voyager-forward`.
- **"knarr runs without distribution":** the running Deployment is the base. Run `just voyager-deploy`.
- **"port-forward ended (1)" or "lost connection to pod":** under the Deployment's `strategy: Recreate`, a rollout that replaces the pod (a deploy with a new image or template, or a restart) ends the forward's target. kubectl keeps the ports bound until the next connection, finds the pod gone, and exits. Run `just voyager-forward` again.

## Exceptions this variant makes

This variant is for inspecting a local cluster with no other tenants. It breaks these rules on purpose:

- **Fixed ports.** Voyager looks up the node through epmd on 4369 and dials the port epmd returns, so both ports are fixed: 4369 and 9100. This contradicts [Decision 0007](../decisions/0007-local-cluster.md)'s "no port is fixed": two worktrees cannot forward at once.
- **An RPC surface.** While Voyager is attached, it can run arbitrary code on a node that holds the Role's pod `patch`. knarr.allium's `NoPodEffects` holds only by convention while it is attached. Inspect; do not mutate ([knarr.allium](../specs/knarr.allium), `Lifecycle` `NoPodEffects`).
- **An unsupervised agent.** On 0.2.0-rc.1, whatever Voyager's agent runs sits outside knarr's supervision tree.
- **A visible cookie.** The pod's environment carries the cookie in `ERL_ZFLAGS`, and the beam command line carries `-setcookie <cookie>`, so `ps` in the pod shows it. The Secret's own last-applied annotation holds it too. On the host, the recipes keep it out of process arguments: `just voyager-deploy` sends the Secret to `kubectl` on stdin, and the probe reads it from a private file.
- **Loopback only.** epmd binds `127.0.0.1` and `::1` in the pod (`ERL_EPMD_ADDRESS`), and the distribution listener binds `127.0.0.1:9100` (`inet_dist_use_interface`). No Service exposes them; `kubectl port-forward`, which dials the pod's `127.0.0.1`, is the path this variant uses.

## Return to the base

Stop the forward with Ctrl-C, then run `just deploy`. The re-apply removes the variant's environment and ports, because `kubectl apply` recorded them. `just smoke` passes afterwards. The `knarr-voyager` Secret stays and is harmless; `just cluster-down` removes it with the cluster.
