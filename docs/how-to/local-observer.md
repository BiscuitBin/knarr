---
title: "Inspect knarr on the local cluster with Observer"
kind: "how-to"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["local_observer"]
requires: []
---

# Inspect knarr on the local cluster with Observer

Erlang's Observer shows a running node's processes, supervision trees, ETS
tables, memory and message queues. Three recipes attach to knarr on this
worktree's kind cluster: `just observer` opens the GUI Observer,
`just observer-cli` runs observer_cli in the terminal, and `just remsh` opens
a remote shell. A fourth, `just observer-cli-install`, prepares observer_cli.
They are a contributor convenience. None of them runs in `just check` or in
any workflow, and the three that attach refuse kwok, whose pods run no
containers.

## Deploy the observer variant

Observer needs Erlang distribution, and knarr ships without it. Start from a
running kind loop, as [the local cluster page](local-cluster.md) describes,
and deploy the `observer` variant instead of the base:

```sh
just cluster-up
just image-build
just deploy knarr:<cluster name> observer
```

`just --evaluate cluster_image` prints the image name. `deploy/observer/` adds
one environment variable and one container port to the base. `ERL_ZFLAGS`
starts the node as `knarr@127.0.0.1` with the cookie `knarr-dev-only`. It
listens for distribution on port 4370, bound to the pod's loopback, and runs
no epmd. The base's `ERL_FLAGS`, which carries knarr's own configuration, is
left as it is. `just smoke` passes on this variant too.

Each recipe below forwards port 4370 with `kubectl port-forward` to a loopback
port the OS picks, and starts a local hidden node that dials it. The local
node listens nowhere and runs no epmd either, so nothing on the host is bound
to a fixed port. Each local node is named after its process, so several
sessions can attach at once. Every recipe runs in the foreground until you
leave it or press Ctrl-C, and the forward ends with it.

## Open the GUI Observer

The GUI needs an Erlang/OTP 29 build with a working wx, the major version the
pod runs. The pixi environments do not have one: conda-forge's OTP ships the
`wx` application without its `wxe_driver`, so `observer:start()` fails with
`{load_driver,"No driver found"}`. Install one outside the repository, for
example with Homebrew, and check it:

```sh
brew install erlang
/opt/homebrew/bin/erl -noshell -eval \
  'io:format("~s ~p~n", [erlang:system_info(otp_release), filelib:wildcard("wxe_driver*", code:priv_dir(wx))]), halt().'
```

It must print `29` and a non-empty list. If Homebrew's formula has moved to
another major, install OTP 29 another way, for example with kerl. Then pass
that `erl` to the recipe, or set `KNARR_OBSERVER_ERL` once:

```sh
just observer /opt/homebrew/bin/erl
```

The recipe runs the `erl` it is given and refuses one whose major is not 29 or
whose wx has no driver. Observer opens with knarr's node selected. Closing its
window ends the recipe.

## Use observer_cli in the terminal

observer_cli is a terminal Observer. It is not a knarr dependency, so it and
recon, which it needs, are compiled locally once:

```sh
just observer-cli-install
just observer-cli
```

`just observer-cli-install` downloads both hex tarballs that
`fixtures/observer/packages.json` pins, observer_cli 2.0.0 and recon 2.5.6,
refuses either unless its sha256 matches, and compiles them with the pixi
`erlc` into `.cluster/observer/ebin/`. It needs no cluster. It needs network,
so agents need explicit authorization for it. A rerun uses the cached
tarballs while their hashes still match.

observer_cli runs its views on the target node, so `just observer-cli` loads
its modules into knarr's memory over distribution for the session and purges
them when you quit with `q`. They never enter the image. Ctrl-C also stops
the port-forward, so a session ended that way cannot remove them: they stay
loaded until the pod restarts, and the next session replaces them. If
observer_cli cannot run on knarr, the recipe prints why and fails.

## Open a remote shell

```sh
just remsh
```

This opens a shell on knarr itself: `i()` lists its processes. Leave with
Ctrl-G then `q`, or Ctrl-C. **`q()` and `init:stop()` stop knarr**, not the
local node, because the shell runs on knarr.

## Why the variant is dev-only

Whoever holds an Erlang cookie can run any code on the node. The cookie here
is a literal published in this page and in `deploy/observer/patch.json`, and
it is not a secret. Distribution therefore lives only in `deploy/observer/`,
for this worktree's kind cluster. It is never in `deploy/base/`,
`deploy/release/`, the image or a chart ([Decision 0012](../decisions/0012-release-and-packaging.md)),
and `scripts/checks/tests/test_deployment.py` fails if the base or the release
overlay names a cookie, a node name, `ERL_ZFLAGS`, `ERL_AFLAGS` or port 4370.
Inside the pod, distribution listens on loopback only, so only a
port-forward, which needs the kubeconfig, reaches it.

Moving observer_cli or recon is a hand edit: change the version, URL and
sha256 in `fixtures/observer/packages.json` together, and run
`just observer-cli-install` and `just observer-cli`. Renovate is kept off both
packages in `.github/renovate.json`.
