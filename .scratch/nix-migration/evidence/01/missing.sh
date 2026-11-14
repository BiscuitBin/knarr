#!/bin/sh
# Ticket 01 evidence: the tools nixpkgs lacks or carries at another version
# than tools.txt, fetched by fixed hash from the upstream release and run from
# the store on aarch64-linux.
# Usage (host): sh nix.sh sh /evidence/missing.sh > missing.txt
# lib.sh sets rev, systems and flake, and the gate runs shellcheck without -x.
# shellcheck disable=SC2154
# shellcheck source=lib.sh disable=SC1091
. /evidence/lib.sh
printf 'date: %s\n%s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(nix --version)" "$(nix config show system)"

# Fetch into the store, print the sha256 in hex and whether it is the pin.
# Prints the store path on the last line. With `executable`, the file is then
# stored a second time with its executable bit: a store file is not executable
# unless it is hashed as a NAR, so that path has a different, Nix-only hash.
fetch() { # url, pinned sha256, [executable]
  result=$(nix store prefetch-file --json --hash-type sha256 "$1" 2> /dev/null)
  hex=$(nix hash convert --hash-algo sha256 --to base16 "$(printf '%s' "$result" | jq -r .hash)")
  if [ "$hex" = "$2" ]; then verdict='matches the pin'; else verdict="DIFFERS from the pin $2"; fi
  printf '%s\n  sha256 %s %s\n' "$1" "$hex" "$verdict" >&2
  [ "$hex" = "$2" ] || exit 1
  if [ "${3:-}" = executable ]; then
    result=$(nix store prefetch-file --json --hash-type sha256 --executable "$1" 2> /dev/null)
    printf '  stored executable under the NAR hash %s\n' "$(printf '%s' "$result" | jq -r .hash)" >&2
  fi
  printf '%s' "$result" | jq -r .storePath
}
runs() { # label, command...
  label=$1
  shift
  if output=$("$@" 2>&1); then
    printf '  %s: %s\n' "$label" "$(printf '%s' "$output" | head -n 1)"
  else
    printf '  %s: FAILS: %s\n' "$label" "$(printf '%s' "$output" | head -n 1)"
  fi
}

printf '\n== allium 3.6.1 (juxt/allium-tools; not in nixpkgs)\n'
printf 'The x86_64-linux and aarch64-darwin digests are the tools.txt pins; aarch64-linux is the\n'
printf 'GitHub asset digest, which tools.txt does not carry.\n'
release=https://github.com/juxt/allium-tools/releases/download/v3.6.1
x86=$(fetch "$release/allium-x86_64-unknown-linux-gnu.tar.gz" e00c99ae234b10207719257a70e7c2dcad73060864468cd293fb7ad40524e970) 2>&1
arm=$(fetch "$release/allium-aarch64-unknown-linux-gnu.tar.gz" e5ce96393db198b4f7d23ccd2494573e753936cc7b03ca1ecbac3cb20f993ff4) 2>&1
mac=$(fetch "$release/allium-aarch64-apple-darwin.tar.gz" ecfae02fcf8e60475a014944183158ccde4104f6f0223e1bf91f98519fcb19eb) 2>&1
rm -rf /work/missing
# `file` without the BuildID, which is a hash and reads as misspelt words.
kind_of() { file -b "$1" | sed 's/, BuildID.*//; s/, Go BuildID.*//' | cut -c1-140; }
unpack() { # system, archive
  mkdir -p "/work/missing/$1"
  tar -xzf "$2" -C "/work/missing/$1"
  printf '%-15s members: %s\n  %s\n' "$1" "$(tar -tzf "$2" | tr '\n' ' ')" "$(kind_of "/work/missing/$1/allium")"
}
unpack x86_64-linux "$x86"
unpack aarch64-linux "$arm"
unpack aarch64-darwin "$mac"
printf 'The unpacked aarch64-linux binary, as fetched (its loader /lib/ld-linux-aarch64.so.1 is not in the Nix image):\n'
runs 'as fetched' /work/missing/aarch64-linux/allium --version
fresh_proto /work/missing/proto
allium=$(nix build --no-link --print-out-paths /work/missing/proto#allium 2> /dev/null)
printf 'The prototype flake derivation (fetchurl by the same sha256, then autoPatchelfHook): %s\n' "$allium"
runs 'from the store' "$allium/bin/allium" --version
printf '  interpreter: %s\n' "$(file -b "$allium/bin/allium" | sed -n 's/.*interpreter \([^,]*\),.*/\1/p')"

printf '\n== kwokctl 0.8.0 (nixpkgs has kwok 0.8.0, which carries kwokctl)\n'
kwok=$(quiet nix build --no-link --print-out-paths "github:NixOS/nixpkgs/$rev#kwok")
printf 'nixpkgs kwok: %s, bin: %s\n' "$kwok" "$(find "$kwok/bin" -mindepth 1 -printf '%f ')"
runs 'from the store' "$kwok/bin/kwokctl" --version
printf 'The upstream asset (tools.txt pins linux-amd64 and darwin-arm64; this is linux-arm64, GitHub asset digest):\n'
kwokctl=$(fetch https://github.com/kubernetes-sigs/kwok/releases/download/v0.8.0/kwokctl-linux-arm64 5a642b27d3e975f36040d215640cd90fb4a63cb6fca0ad5865a61bcd9c81051b executable) 2>&1
printf '  %s\n' "$(kind_of "$kwokctl")"
runs 'as fetched, from the store' "$kwokctl" --version

printf '\n== hadolint (tools.txt pins 2.15.1; nixpkgs has 2.14.0)\n'
hadolint=$(quiet nix build --no-link --print-out-paths "github:NixOS/nixpkgs/$rev#hadolint")
runs 'nixpkgs' "$hadolint/bin/hadolint" --version
printf 'The upstream asset (tools.txt pins linux-x86_64 and macos-arm64; this is linux-arm64, GitHub asset digest):\n'
upstream=$(fetch https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-arm64 f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d executable) 2>&1
printf '  %s\n' "$(kind_of "$upstream")"
runs 'as fetched, from the store' "$upstream" --version

printf '\n== grype (pixi.toml pins 0.120.1; nixpkgs has 0.120.0)\n'
grype=$(quiet nix build --no-link --print-out-paths "github:NixOS/nixpkgs/$rev#grype")
runs 'nixpkgs' "$grype/bin/grype" --version

printf '\n== The other tools.txt tools, from nixpkgs at the pinned version\n'
for tool in ripsecrets editorconfig-checker kubeconform; do
  stored=$(quiet nix build --no-link --print-out-paths "github:NixOS/nixpkgs/$rev#$tool")
  case $tool in
    kubeconform) runs "$tool" "$stored/bin/$tool" -v ;;
    *) runs "$tool" "$stored/bin/$tool" --version ;;
  esac
done
rebar3=$(quiet nix build --no-link --print-out-paths "github:NixOS/nixpkgs/$rev#beam_minimal.packages.erlang_29.rebar3")
runs rebar3 "$rebar3/bin/rebar3" --version
