#!/bin/sh
# Ticket 08 evidence: a fresh clone of the committed branch, initialized with
# the Nix backend; the stand-in host's Docker client; the guards before the
# optional groups exist; then `just cluster-install` and `just audit-install`
# and what each group holds. Needs the network: the flake's inputs and the hex
# packages.
# Usage (Mac): sh host.sh sh /evidence/setup.sh > setup.txt
set -eu
clone=$WORK/clone
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(uname -m)"
git config --global user.name 'ticket 08'
git config --global user.email ticket08@example.invalid
git config --global advice.detachedHead false
rm -rf "$clone" "$WORK/clone-probe" "$WORK/probe"
git clone --quiet --branch 08-cluster-audit-tools-from-flake /bundle/knarr.bundle "$clone"
cd "$clone"
printf 'clone of %s at %s\n' "$(git branch --show-current)" "$(git rev-parse --short=12 HEAD)"

printf '\n== KNARR_TOOLS=nix sh scripts/initialize.sh\n'
KNARR_TOOLS=nix sh scripts/initialize.sh > "$WORK/setup-initialize.log" 2>&1
grep -E '^(Ready|Nothing has been)' "$WORK/setup-initialize.log"
printf '.nix: %s\n' "$(cd .nix && printf '%s ' *)"

# Docker is a host prerequisite. The Ubuntu stand-in has none, so its client
# and the buildx plugin the Dockerfile's BuildKit syntax needs come from the
# flake's locked main input, outside the checkout. No recipe runs this.
printf '\n== The stand-in host Docker client (not part of the checkout)\n'
rm -rf "$WORK/host"
mkdir -p "$WORK/host/bin" "$HOME/.docker/cli-plugins"
nix build --no-update-lock-file --inputs-from . --out-link "$WORK/host/docker-client" nixpkgs#docker-client
nix build --no-update-lock-file --inputs-from . --out-link "$WORK/host/docker-buildx" nixpkgs#docker-buildx
ln -sf "$WORK/host/docker-client/bin/docker" "$WORK/host/bin/docker"
ln -sf "$WORK/host/docker-buildx/bin/docker-buildx" "$HOME/.docker/cli-plugins/docker-buildx"
docker version --format 'client {{.Client.Version}}, daemon {{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'
docker buildx version

just=$clone/.nix/default/bin/just
printf '\n== Before either group is installed, with a host kind, kubectl and grype on PATH\n'
mkdir -p "$WORK/runner/bin"
for tool in kind kubectl kwokctl grype; do
  printf '#!/bin/sh\necho "the host %s ran" >&2\n' "$tool" > "$WORK/runner/bin/$tool"
  chmod 755 "$WORK/runner/bin/$tool"
done
for recipe in cluster-up cluster-ready deploy smoke image-scan runtime-scan; do
  status=0
  KNARR_TOOLS=nix PATH="$PATH:$WORK/runner/bin" "$just" "$recipe" > "$WORK/guard.log" 2>&1 || status=$?
  printf 'just %-13s exit %s: %s\n' "$recipe" "$status" "$(grep -v '^sh scripts' "$WORK/guard.log" | tr '\n' ' ')"
done

printf '\n== KNARR_TOOLS=nix just cluster-install\n'
KNARR_TOOLS=nix "$just" cluster-install 2>&1 | tail -n 3
printf '== KNARR_TOOLS=nix just audit-install\n'
KNARR_TOOLS=nix "$just" audit-install 2>&1 | tail -n 3
for group in cluster audit; do
  printf '.nix/%s -> %s\n  bin: %s\n' "$group" "$(readlink .nix/$group)" "$(cd .nix/$group/bin && printf '%s ' *)"
done
printf 'git status --short: %s lines\n' "$(git status --short | wc -l)"

printf '\n== What recipes find under KNARR_TOOLS=nix\n'
dirs=$(KNARR_TOOLS=nix sh scripts/tool-dirs.sh dirs)
for tool in kind kubectl kwokctl grype helm kustomize; do
  printf '%-10s %s\n' "$tool" "$(PATH=$dirs:$PATH command -v "$tool")"
done
PATH=$dirs:$PATH
printf 'kind version: %s\n' "$(kind version)"
printf 'kubectl version --client: %s\n' "$(kubectl version --client | tr '\n' ' ')"
printf 'kwokctl --version: %s\n' "$(kwokctl --version)"
printf 'grype version: %s\n' "$(grype version | grep -E '^(Version|Syft Version):' | tr -s ' ' | tr '\n' ' ')"
printf 'pins.toml: %s\n' "$(grep -E '^(kind|kwokctl|kubectl) =' pins.toml | tr '\n' ' ')"

printf '\n== The guards pass once the groups are installed\n'
KNARR_TOOLS=nix sh scripts/tool-group.sh check cluster && echo 'check cluster: exit 0'
KNARR_TOOLS=nix sh scripts/tool-group.sh check audit && echo 'check audit: exit 0'

printf '\n== KNARR_TOOLS=nix just env-check, with the cluster group installed\n'
start=$(date +%s)
KNARR_TOOLS=nix "$just" env-check 2>&1 | sed "s|$WORK|\$WORK|g"
printf 'seconds: %s\n' "$(($(date +%s) - start))"
