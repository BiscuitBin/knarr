#!/bin/sh
# Ticket 07 evidence: a fresh clone of the committed branch, initialized with
# the Nix backend. Needs the network: the flake's inputs and the hex packages.
# The clone is the primary checkout, so `just initialize` installs the hook.
# Usage (Mac): sh host.sh sh /evidence/setup.sh > setup.txt
set -eu
clone=/work/clone
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
git config --global user.name 'ticket 07'
git config --global user.email ticket07@example.invalid
git config --global advice.detachedHead false
rm -rf "$clone"
git clone --quiet --branch 07-flake-beside-pixi /bundle/knarr.bundle "$clone"
cd "$clone"
printf 'clone of %s at %s\n' "$(git branch --show-current)" "$(git rev-parse --short HEAD)"
printf 'tracked: %s\n' "$(git ls-files flake.nix flake.lock pins.toml | tr '\n' ' ')"

printf '\n== KNARR_TOOLS=nix sh scripts/initialize.sh (there is no just before it)\n'
start=$(date +%s)
KNARR_TOOLS=nix sh scripts/initialize.sh > /work/setup-initialize.log 2>&1
printf 'exit 0 in %s seconds\n' "$(($(date +%s) - start))"
grep -E '^(Ready|Nothing has been)' /work/setup-initialize.log
printf '.nix/default -> %s\n' "$(readlink .nix/default)"
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"
printf 'git check-ignore: %s\n' "$(git check-ignore .nix/default)"

printf '\n== The hook names the out-link, never a store path\n'
grep '^PREK=' .git/hooks/pre-commit
printf 'store paths in the hook: %s\n' "$(grep -c '/nix/store/' .git/hooks/pre-commit || true)"
printf 'the hook resolves to %s\n' "$(readlink -f "$clone/.nix/default/bin/prek")"

printf '\n== What recipes see under KNARR_TOOLS=nix\n'
just=$clone/.nix/default/bin/just
KNARR_TOOLS=nix "$just" --evaluate PATH | tr ':' '\n' | head -n 4
dirs=$(KNARR_TOOLS=nix sh scripts/tool-dirs.sh dirs)
for tool in perl python3 node gleam erl rebar3 openssl allium prek just markdownlint-cli2 ripsecrets; do
  printf '%-18s %s\n' "$tool" "$(PATH=$dirs:$PATH command -v "$tool")"
done
printf 'markdownlint-cli2 module: %s\n' "$(KNARR_TOOLS=nix sh scripts/tool-dirs.sh module markdownlint-cli2)"
printf 'perl: %s\n' "$(PATH=$dirs:$PATH perl -e 'print $^V')"
printf 'ripsecrets in the store: mode %s\n' "$(stat -L -c %a .nix/default/bin/ripsecrets)"
