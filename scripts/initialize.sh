#!/bin/sh
# `just initialize`: the one first-run command, and the only step that needs
# network. On a fresh clone with no `just` installed, run it as
# `sh scripts/initialize.sh`; it sets its own PATH, so it needs only pixi. It writes only ignored paths (.pixi/, .tools/, build/) and, in the
# primary checkout, .git/hooks. It never formats, stages, commits or pushes.
# Rerunning it is safe; with everything already present it needs no network.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
PATH="$root/.pixi/envs/default/bin:$root/.pixi/envs/cluster/bin:$root/.tools/bin:$PATH"
PYTHONDONTWRITEBYTECODE=1
export PATH PYTHONDONTWRITEBYTECODE
git rev-parse --is-inside-work-tree > /dev/null

command -v pixi > /dev/null ||
  { printf '%s\n' 'pixi is not installed; see README.md, Getting started' >&2; exit 2; }

# The compiler, OTP, Python and every gate tool, exactly as pixi.lock pins
# them. --locked refuses a lock that disagrees with pixi.toml rather than
# rewriting it.
pixi install --locked

# What conda-forge lacks (rebar3, ripsecrets, editorconfig-checker), each
# refused unless its sha256 matches tools.txt.
sh scripts/install-tools.sh tools.txt .tools/bin

# Gleam's hex packages into build/, so later builds run offline. The pre-check
# first: `gleam deps download` would silently rewrite a drifted manifest.toml.
python3 scripts/checks/manifest_check.py
before=$(cksum < manifest.toml)
gleam deps download
[ "$(cksum < manifest.toml)" = "$before" ] ||
  { printf '%s\n' 'gleam deps download rewrote manifest.toml; read the diff' >&2; exit 1; }

# The fake worker fixture is a second Gleam project (ticket 29), with the same
# pre-check and guard.
python3 scripts/checks/manifest_check.py fixtures/fake_worker
before=$(cksum < fixtures/fake_worker/manifest.toml)
(cd fixtures/fake_worker && gleam deps download)
[ "$(cksum < fixtures/fake_worker/manifest.toml)" = "$before" ] ||
  { printf '%s\n' 'gleam deps download rewrote fixtures/fake_worker/manifest.toml; read the diff' >&2; exit 1; }

sh scripts/install-hooks.sh

printf '\n%s\n' 'Ready. Next: just check (no network needed).'
printf '%s\n' 'Nothing has been staged, committed or pushed.'
