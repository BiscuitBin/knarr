#!/bin/sh
# Ticket 05 evidence: realise the prototype flake's groups on the CI runner,
# into the directories every recipe already reads, and time each step.
# Ticket 01's gate-setup.sh did the same in a container: the out-link is
# .pixi/envs/<group> and .tools/bin links to the default group's bin, so no
# tracked file changes. Then the hex packages, as `just initialize` does.
# Runs at the repository root, after Nix is installed (nix-spike.yml).
# Usage: sh setup.sh <group>...   (default, cluster or audit)
set -eu
proto=./.scratch/nix-migration/evidence/01
logs=${RUNNER_TEMP:-/tmp}/setup-logs
mkdir -p "$logs"
since() { # start, as date +%s.%N printed it
  echo "$(date +%s.%N) $1" | awk '{ printf "%.1f", $1 - $2 }'
}
store() { printf '%s paths, %s' "$(find /nix/store -mindepth 1 -maxdepth 1 | wc -l)" "$(du -sh /nix/store 2> /dev/null | cut -f1)"; }

# shellcheck disable=SC1091 # the runner's own file
. /etc/os-release
printf 'date: %s\nrunner: %s, %s, %s cores, %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -sm)" "$PRETTY_NAME" \
  "$(nproc)" "$(free -g | awk '/^Mem:/ { print $2 " GiB memory" }')"
printf 'commit: %s\n%s, system %s\n' "$(git rev-parse HEAD)" "$(nix --version)" "$(nix config show system)"
for setting in experimental-features sandbox build-users-group max-jobs substituters trusted-public-keys always-allow-substitutes; do
  printf '  %s = %s\n' "$setting" "$(nix config show "$setting")"
done
if [ -n "$(nix config show access-tokens)" ]; then echo '  access-tokens: set'; else echo '  access-tokens: empty (no token)'; fi
printf 'store before: %s\n' "$(store)"

for group; do
  link=.pixi/envs/$group
  start=$(date +%s.%N)
  nix build "$proto#$group" --no-update-lock-file --out-link "$link" > "$logs/$group.log" 2>&1 ||
    { cat "$logs/$group.log"; exit 1; }
  printf '\nnix build %s#%s --no-update-lock-file --out-link %s: %ss\n' "$proto" "$group" "$link" "$(since "$start")"
  grep -E '^(this|these) [0-9]+ (derivation|path)' "$logs/$group.log" | sed 's/^/  /' || echo '  nothing to build or fetch'
  printf '  -> %s\n  closure: %s\n' "$(readlink "$link")" "$(nix path-info -Sh "$link" | cut -f2-)"
done
mkdir -p .tools
ln -sfn ../.pixi/envs/default/bin .tools/bin
printf '\nstore after: %s\n' "$(store)"
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"

# The Justfile's PATH, the order every recipe sees.
root=$(pwd -P)
PATH=$root/.pixi/envs/default/bin:$root/.pixi/envs/cluster/bin:$root/.pixi/envs/audit/bin:$root/.tools/bin:$PATH
export PATH

printf '\n== Hex packages, as just initialize fetches them\n'
start=$(date +%s.%N)
python3 scripts/checks/manifest_check.py
before=$(cksum < manifest.toml)
gleam deps download > "$logs/hex.log" 2>&1 || { cat "$logs/hex.log"; exit 1; }
python3 scripts/checks/manifest_check.py fixtures/fake_worker
(cd fixtures/fake_worker && gleam deps download) >> "$logs/hex.log" 2>&1 || { cat "$logs/hex.log"; exit 1; }
[ "$(cksum < manifest.toml)" = "$before" ] && echo 'manifest.toml unchanged'
printf 'both gleam deps download: %ss\n' "$(since "$start")"

printf '\n== Where each tool resolves on the Justfile PATH (the runner image ships its own copies of some)\n'
for tool in gleam erl rebar3 python3 node just prek lychee markdownlint-cli2 helm kubeconform hadolint allium \
  kind kubectl kwokctl grype; do
  if found=$(command -v "$tool"); then
    printf '%-18s %s\n' "$tool" "$(readlink -f "$found" | sed 's,^/nix/store/[a-z0-9]\{32\}-,/nix/store/…-,')"
  else
    printf '%-18s %s\n' "$tool" 'not on PATH'
  fi
done
printf 'versions: gleam %s; %s; allium %s; just %s\n' "$(gleam --version | cut -d' ' -f2)" \
  "$(erl -noshell -eval 'io:format("OTP ~s, erts ~s", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().')" \
  "$(allium --version | cut -d' ' -f2)" "$(just --version | cut -d' ' -f2)"
if [ -e .pixi/envs/cluster ]; then
  printf 'cluster: kind %s; kubectl %s; kwokctl %s\n' "$(kind version | cut -d' ' -f2)" \
    "$(kubectl version --client 2> /dev/null | sed -n 's/^Client Version: //p')" "$(kwokctl --version | cut -d' ' -f3)"
fi
printf 'allium on x86_64: %s\n' "$(file -b "$(readlink -f "$(command -v allium)")" | cut -d, -f1-2,5)"
