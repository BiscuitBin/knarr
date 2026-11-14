# shellcheck shell=sh
# Ticket 01 evidence: shared by the scripts that run inside the container
# (sh nix.sh sh /evidence/<script>.sh). Sourced, never run.
#
# The Nix image has coreutils, grep, git and curl only, so the text tools the
# scripts use come from the candidate revision itself.
set -eu
flake=/evidence
cache=https://cache.nixos.org
# shellcheck disable=SC2034 # read by the scripts that source this
systems="aarch64-linux x86_64-linux aarch64-darwin"

# The locked revision of one flake input, read from flake.lock.
locked() {
  nix eval --raw --impure --expr \
    "(builtins.fromJSON (builtins.readFile $flake/flake.lock)).nodes.\"$1\".locked.rev" 2> /dev/null
}

# "yes" when cache.nixos.org has the store path, "no" otherwise.
cached() {
  if nix path-info --store "$cache" "$1" > /dev/null 2>&1; then echo yes; else echo no; fi
}

# nixpkgs prints an evaluation warning for the deprecated top-level erlang.
quiet() { "$@" 2> /dev/null; }

rev=$(locked nixpkgs)
probe=$(nix build --no-link --print-out-paths --impure --expr "
  with (builtins.getFlake \"github:NixOS/nixpkgs/$rev\").legacyPackages.\${builtins.currentSystem};
  buildEnv { name = \"probe-tools\"; paths = [ gawk gnused jq file diffutils findutils gnutar gzip time ]; }" 2> /dev/null)
PATH=$probe/bin:$PATH
export PATH

# What a machine with an empty store would build and fetch for one flake
# output: evaluated and planned in an empty chroot store, which then holds only
# the flake's sources. The paths counted are everything the build needs,
# build-time tools included, so they are more than the output's closure.
plan() {
  nix build --dry-run --store /work/empty-store "$1" 2>&1 |
    grep -E 'will be (built|fetched)|\.drv$' || echo '(nothing to build or fetch)'
}

# A scratch copy of the prototype flake, as a plain directory (a path: flake).
fresh_proto() {
  rm -rf "$1"
  mkdir -p "$1"
  cp "$flake/flake.nix" "$flake/flake.lock" "$1"/
}

# The Nix image is not a POSIX host: it has no sed, awk, find or diff, which
# the repository's scripts expect from the machine (Decision 0003 keeps "a
# POSIX shell" a prerequisite). This environment stands in for the host's own
# utilities. It goes after the image's PATH, and is not part of the prototype.
host_posix() {
  nix build --no-link --print-out-paths --impure --expr "
    with (builtins.getFlake \"github:NixOS/nixpkgs/$rev\").legacyPackages.\${builtins.currentSystem};
    buildEnv { name = \"host-posix\"; paths = [ gnused gawk findutils diffutils ]; }" 2> /dev/null
}
