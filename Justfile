set positional-arguments := true
set shell := ["sh", "-eu", "-c"]

# Recipes reach every tool through PATH, never `pixi run` (Decision 0003): on a
# stale lock `pixi run` re-solves and rewrites pixi.lock. The default
# environment comes first, so gleam and the shared tools always resolve from
# it; the cluster and audit environments' tools resolve only once each is
# installed; then the checksum-pinned downloads from tools.txt.
export PATH := justfile_directory() / ".pixi" / "envs" / "default" / "bin" + ":" + justfile_directory() / ".pixi" / "envs" / "cluster" / "bin" + ":" + justfile_directory() / ".pixi" / "envs" / "audit" / "bin" + ":" + justfile_directory() / ".tools" / "bin" + ":" + env("PATH")

# Python would otherwise write __pycache__/ beside the checkers it runs.
export PYTHONDONTWRITEBYTECODE := "1"

# Any recipe may write ignored paths, such as build/ and the <title>.new a
# failing snapshot test leaves. Five recipes change tracked files on purpose:
# `fix`, `snapshots-review`, `snapshots-accept`, `release-pin`, and `birdie`
# running `accept`, `reject` or `stale delete`. None is in the check group, and
# `just check` proves its recipes change nothing Git can see.

# birdie keeps the list of snapshots a test run referenced in $TMPDIR, named by
# project only, so every worktree would share one list. Each recipe that runs
# birdie points TMPDIR here instead. It is set per recipe, not exported: the
# gate runner and pytest's tmp_path also read TMPDIR.
birdie_tmpdir := justfile_directory() / "build" / "birdie"
[private]
default:
    @just --list

# ------------------------------------------------------------------ setup ---

# The one first-run command; it needs network, as does links-audit: the pixi
# environment, the tools.txt downloads, and Gleam's hex packages. Hooks install
# from the primary checkout only. Never stages, commits or pushes.
[group('setup')]
[doc('First run (needs network): pixi environment, tools.txt downloads, hex packages, hooks')]
initialize:
    sh scripts/initialize.sh

# ---------------------------------------------------------------- develop ---

# Warnings are errors here and in the gate alike. Each gleam recipe compares
# manifest.toml before and after, the backstop for a rewrite manifest-check
# cannot predict (Decision 0003); the snapshot runner also catches it in the
# gate.
[group('develop')]
[group('check')]
[doc('Build with warnings as errors (refuses a drifted manifest.toml)')]
build: manifest-check
    before=$(cksum < manifest.toml); gleam build --warnings-as-errors; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote manifest.toml; run just manifest-check' >&2; exit 1; }

# A new or changed snapshot fails here. birdie then writes the new picture
# beside the accepted one as <title>.new, which is ignored, so the gate stays
# read-only; `just snapshots-review` shows it. Every .new is removed first, so
# those left afterwards are this run's, and no accept takes an older picture.
# So is the referenced list, which birdie empties only when a run reads an
# accepted snapshot.
[group('develop')]
[group('check')]
[doc('Run the Gleam tests, snapshot tests included (refuses a drifted manifest.toml)')]
test: manifest-check
    mkdir -p "{{ birdie_tmpdir }}"; rm -f "{{ birdie_tmpdir }}/knarr_referenced.txt" test/birdie_snapshots/*.new
    before=$(cksum < manifest.toml); ERL_FLAGS="${ERL_FLAGS:-} -knarr port 0 bind '\"127.0.0.1\"'" TMPDIR="{{ birdie_tmpdir }}" gleam test; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote manifest.toml; run just manifest-check' >&2; exit 1; }

# Report only, outside the gate. The boot hook and reports stay under build/.
[group('develop')]
[doc('Run the Gleam tests with source-line coverage (no floor; reports under build/coverage)')]
coverage:
    python3 scripts/checks/coverage.py

# `stale check` reads the list the last `just test` wrote: run without one, it
# fails. It runs only if the tests pass, because a test that fails before it
# snaps leaves its snapshot unreferenced, and so falsely stale. Neither command
# here prompts or writes a tracked file.
[group('develop')]
[doc('Run the tests and, if they pass, list accepted snapshots no test referenced')]
snapshots-stale: test (birdie "stale" "check")

# The tests run first, their failure ignored, so every .new is a picture from
# this run. Accepting writes tracked files under test/birdie_snapshots/.
[group('develop')]
[doc('Rerun the tests, then review each new or changed snapshot interactively')]
snapshots-review:
    -{{ just_executable() }} test
    {{ just_executable() }} birdie review

# For agents: accepts every pending snapshot without prompting. It writes
# tracked files, so read their diff before committing.
[group('develop')]
[doc('Rerun the tests, then accept every new or changed snapshot (writes tracked files)')]
snapshots-accept:
    -{{ just_executable() }} test
    {{ just_executable() }} birdie accept

# birdie's command line, with this worktree's TMPDIR and the manifest guard:
# `just birdie reject`, `just birdie stale delete`. A bare `gleam run -m
# birdie stale ...`, as birdie's own hints suggest, reads the shared list in
# the system's TMPDIR instead.
[group('develop')]
[doc("Run a birdie command (reject, stale delete) with this worktree's TMPDIR")]
birdie +arguments: manifest-check
    mkdir -p "{{ birdie_tmpdir }}"
    before=$(cksum < manifest.toml); ERL_FLAGS="${ERL_FLAGS:-} -knarr port 0 bind '\"127.0.0.1\"'" TMPDIR="{{ birdie_tmpdir }}" gleam run --no-print-progress -m birdie "$@"; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote manifest.toml; run just manifest-check' >&2; exit 1; }

# The fake worker (ticket 29) is its own Gleam project under fixtures/, so
# knarr's shipment never carries it and running it never boots knarr. These
# recipes mirror manifest-check, build, test and lint-gleam for that project,
# with the same manifest guard. knarr's own recipes never depend on them: the
# cold-build and coverage tests copy only the root project.
[group('develop')]
[group('check')]
[doc("Fail if the fake worker's manifest.toml disagrees with its gleam.toml")]
fake-worker-manifest-check:
    python3 scripts/checks/manifest_check.py fixtures/fake_worker

[group('develop')]
[group('check')]
[doc('Build the fake worker fixture with warnings as errors')]
fake-worker-build: fake-worker-manifest-check
    cd fixtures/fake_worker && before=$(cksum < manifest.toml); gleam build --warnings-as-errors; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote fixtures/fake_worker/manifest.toml; run just fake-worker-manifest-check' >&2; exit 1; }

[group('develop')]
[group('check')]
[doc("Run the fake worker's Gleam tests")]
fake-worker-test: fake-worker-manifest-check
    cd fixtures/fake_worker && before=$(cksum < manifest.toml); gleam test; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote fixtures/fake_worker/manifest.toml; run just fake-worker-manifest-check' >&2; exit 1; }

# glinter reads gleam.toml from the directory it runs in.
[group('check')]
[doc('Lint the fake worker with glinter, warnings as errors')]
fake-worker-lint: fake-worker-build
    cd fixtures/fake_worker && before=$(cksum < manifest.toml); sh ../../scripts/checks/run_glinter.sh; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote fixtures/fake_worker/manifest.toml; run just fake-worker-manifest-check' >&2; exit 1; }

# The gate checkers' own tests (scripts/checks/tests/). The fake worker's
# process tests there run its build.
[group('develop')]
[group('check')]
[doc("Run the gate checkers' own tests")]
test-checkers: build fake-worker-build
    python3 -m pytest

# ----------------------------------------------------------------- format ---

# Automatic repairs through the fix config, which rewrites tracked files. The
# config runs twice because one fixer's first pass may leave what another then
# repairs.
[group('format')]
[doc('Repair formatting and lint findings in place (edits tracked files)')]
fix:
    -prek run --all-files --config .pre-commit-fix.yaml
    prek run --all-files --config .pre-commit-fix.yaml

# ------------------------------------------------------------------ check ---

# --dry-run, because plain `pixi lock --check` rewrites a stale lock even as it
# fails; --offline, because the gate never fetches (Decision 0003).
[group('check')]
[doc('Fail if pixi.lock disagrees with pixi.toml, without rewriting it')]
lock-check:
    pixi lock --check --offline --dry-run

# lock-check reads pixi.lock and pixi.toml only. After a pull that moves a pin
# the old binaries stay on PATH until `just initialize` reruns, so this fails
# while the installed default environment or .tools/bin differs from the pins.
[group('check')]
[doc('Fail if the installed tools differ from pixi.lock or tools.txt')]
env-check:
    python3 scripts/checks/env_check.py

# gleam rewrites a manifest.toml that disagrees with gleam.toml and exits 0, so
# this compares the two first and fails instead (Decision 0003, Verify 5).
[group('check')]
[doc('Fail if manifest.toml disagrees with gleam.toml, without rewriting it')]
manifest-check:
    python3 scripts/checks/manifest_check.py

[group('check')]
[doc('Validate documentation metadata, registration, links, and reachability')]
docs-check:
    python3 scripts/checks/validate_docs.py

# The agent surface: AGENTS.md's required phrases, the byte-pinned adapters,
# the house skills with a bridge per runtime, and the vendored skills against
# skills-lock.json (Decision 0004, ticket 09).
[group('check')]
[doc('Validate AGENTS.md, its adapters, the skills, their bridges and skills-lock.json')]
agents-check:
    python3 scripts/checks/validate_agents.py

# Online checks stay outside the read-only, offline gate. Include hidden
# bootstrap docs, while excluding Git internals and generated directories.
[group('audit')]
[doc('Check Markdown and HTML links online (separate from the offline gate)')]
links-audit:
    lychee --no-progress --include-fragments --hidden --extensions md,html,htm --exclude-path '(^|/)(\.git|\.pixi|\.tools|build|ai_tmp)/' .

# OSV.dev's answer changes without a commit, so this runs in the audit
# workflow, never in the gate (Decision 0014).
[group('audit')]
[doc('Check the hex packages and the OTP pin against OSV.dev advisories (needs network)')]
hex-audit:
    python3 scripts/checks/hex_audit.py

# Fails on a high or critical vulnerability that has a fix. grype downloads its
# vulnerability database on first use. It reads the image's OS packages only,
# not the conda records of the runtime environment the image ships, so a pass
# says nothing about erlang, its openssl or perl (Decision 0014, ticket 45).
[group('audit')]
[doc('Scan the OS packages of an image for fixable high and critical vulnerabilities with grype (needs network)')]
image-scan image=cluster_image: audit-tools
    grype "$1" --only-fixed --fail-on high

[private]
audit-tools:
    test -x .pixi/envs/audit/bin/grype || { echo 'run just audit-install' >&2; exit 2; }

[group('check')]
[doc('Fail on unformatted Gleam')]
format-check:
    gleam format --check src test fixtures/fake_worker/src fixtures/fake_worker/test

# [tools.glinter] in gleam.toml sets what is linted and the rules. glinter
# passes when it skips a file it cannot parse; the wrapper fails instead.
# Build first: running a dependency module starts our OTP application without
# compiling the application modules that its Erlang callback calls.
[group('check')]
[doc('Lint src/ and test/ with glinter, warnings as errors (refuses a drifted manifest.toml)')]
lint-gleam: build
    before=$(cksum < manifest.toml); ERL_FLAGS="${ERL_FLAGS:-} -knarr port 0 bind '\"127.0.0.1\"'" sh scripts/checks/run_glinter.sh; [ "$(cksum < manifest.toml)" = "$before" ] || { echo 'gleam rewrote manifest.toml; run just manifest-check' >&2; exit 1; }

# birdie has no check mode: `just test`, which runs just before this in the
# gate, has already failed on a new or changed snapshot. Run on its own, after
# a failing `just test`, this names each pending .new. Then it fails on an
# accepted snapshot the last `just test` did not reference.
[group('check')]
[doc('Fail on a pending or stale snapshot (reads what the last just test left)')]
snapshots-check: snapshots-pending (birdie "stale" "check")

[private]
snapshots-pending:
    [ -d test/birdie_snapshots ] || exit 0; pending=$(find test/birdie_snapshots -type f -name '*.new'); [ -z "$pending" ] || { printf '%s\n' "$pending" | sort >&2; echo 'pending snapshots: review them with just snapshots-review' >&2; exit 1; }

[group('check')]
[doc('Fail on unformatted or invalid TOML')]
toml-check:
    taplo fmt --check
    taplo lint

# Every read-only hook over every file: typos, markdownlint, shellcheck,
# editorconfig-checker, ruff, lychee (offline), actionlint, ripsecrets, and
# prek's builtin checks. The gleam-format and taplo hooks are skipped here
# because format-check and toml-check run them as their own gate recipes.
[group('check')]
[doc('Run every read-only hook over every file')]
lint:
    SKIP=gleam-format,taplo prek run --all-files

# Allium reports diagnostics independently of its exit status.
[group('check')]
[doc('Fail on any Allium diagnostic')]
check-specs:
    python3 scripts/checks/run_allium.py check

[group('check')]
[doc('Fail on any Allium analysis finding or diagnostic')]
analyse-specs:
    python3 scripts/checks/run_allium.py analyse

[group('develop')]
[doc('Print the test plan and obligation count for one Allium module')]
plan-spec module:
    python3 scripts/checks/run_allium.py plan "$1"

# The runner calls this last, with the baseline it snapshotted.
[group('check')]
[doc('Fail if the worktree differs from the baseline (or, without one, is not clean)')]
check-clean baseline="":
    python3 scripts/checks/run_project_check.py clean "$1"

# The complete gate. The runner snapshots the worktree, runs each recipe and
# fails on the first change to any tracked or untracked-unignored file, even
# when the recipe passed, then runs check-clean. A lane adds its validator to
# this list.
[group('check')]
[doc('The complete read-only gate')]
check:
    test -x .pixi/envs/default/bin/python3 || { printf '%s\n' 'the pixi environment is missing; run just initialize' >&2; exit 2; }
    python3 scripts/checks/run_project_check.py run lock-check env-check manifest-check docs-check agents-check check-specs analyse-specs format-check lint-gleam build test snapshots-check fake-worker-manifest-check fake-worker-build fake-worker-test fake-worker-lint test-checkers packaging-check toml-check lint

# --------------------------------------------------------------- cluster ---
# Cluster effects are deliberately outside the offline repository gate.
cluster_image := "knarr:" + `sh scripts/cluster-name.sh . name`

[private]
cluster-tools:
    test -x .pixi/envs/cluster/bin/kind || { echo 'run pixi install --locked -e cluster' >&2; exit 2; }

[group('cluster')]
[doc('Create or reuse this worktree cluster (may download images)')]
cluster-up: cluster-tools
    python3 scripts/checks/cluster.py up "{{ justfile_directory() }}"

[group('cluster')]
[doc('Delete this worktree cluster and its local state')]
cluster-down: cluster-tools
    python3 scripts/checks/cluster.py down "{{ justfile_directory() }}"

[group('cluster')]
[doc('Wait for this worktree cluster node and default ServiceAccount')]
cluster-ready: cluster-tools
    python3 scripts/checks/cluster.py ready "{{ justfile_directory() }}"

[group('cluster')]
[doc('Build the linux/amd64 shipment image (needs network)')]
image-build image=cluster_image:
    docker build --platform linux/amd64 --tag "$1" .

[group('cluster')]
[doc('Load a local image into this worktree kind cluster')]
image-load image=cluster_image: cluster-tools
    python3 scripts/checks/cluster.py image-load "{{ justfile_directory() }}" "$1"

# The variant is a directory under deploy/ with a kustomization: `base`, or
# `wrong-ca` for the negative TLS case (ticket 14).
[group('cluster')]
[doc('Load and deploy the base, or a deploy/ variant, to this worktree kind cluster')]
deploy image=cluster_image variant="base": cluster-tools
    python3 scripts/checks/cluster.py deploy "{{ justfile_directory() }}" "$1" "$2"

[group('cluster')]
[doc('Check all three endpoints through a temporary loopback port forward')]
smoke: cluster-tools
    python3 scripts/checks/cluster.py smoke "{{ justfile_directory() }}"

[group('cluster')]
[doc('Print this worktree cluster pods, events and application logs')]
cluster-diagnostics: cluster-tools
    python3 scripts/checks/cluster.py diagnostics "{{ justfile_directory() }}"

[group('setup')]
[doc('Install the locked optional cluster environment (needs network)')]
cluster-install:
    pixi install --locked -e cluster

[group('setup')]
[doc('Install the locked optional audit environment, grype (needs network)')]
audit-install:
    pixi install --locked -e audit

[group('cluster')]
[doc('Verify image OTP ownership and restricted runtime startup')]
image-check image=cluster_image:
    python3 scripts/checks/image.py "$1"

[group('check')]
[doc("Lint both images and validate the base and fake worker resources against pinned local schemas")]
packaging-check:
    hadolint Dockerfile fixtures/fake_worker/Dockerfile
    python3 scripts/checks/deployment.py

# The fake worker fixture on kind (ticket 29). Its image builds from the
# repository root, with its own Dockerfile and context allowlist beside it.
fake_worker_image := replace(cluster_image, "knarr:", "fake-worker:")

[group('cluster')]
[doc('Build the linux/amd64 fake worker image (needs network)')]
fake-worker-image-build image=fake_worker_image:
    docker build --platform linux/amd64 --file fixtures/fake_worker/Dockerfile --tag "$1" .

[group('cluster')]
[doc('Verify the fake worker image: numeric user, OTP, restricted runtime and a SIGTERM drain')]
fake-worker-image-check image=fake_worker_image:
    python3 scripts/checks/image.py --fake-worker "$1"

[group('cluster')]
[doc('Load and deploy four fake workers and their collector to this worktree kind cluster')]
fake-worker-deploy image=fake_worker_image: cluster-tools
    python3 scripts/checks/cluster.py fake-worker-deploy "{{ justfile_directory() }}" "$1"

[group('cluster')]
[doc('Set mixed states through control, read them back from status, and find kill records')]
fake-worker-smoke: cluster-tools
    python3 scripts/checks/cluster.py fake-worker-smoke "{{ justfile_directory() }}"

[group('cluster')]
[doc('Render and validate every deploy/ variant, and hold the release overlay to its two-line difference')]
deployment-check: cluster-tools
    python3 scripts/checks/deployment.py --render

# ---------------------------------------------------------------- release ---

# Writes deploy/release/kustomization.yaml, a tracked file, so it is outside the
# check group. Ticket 37 runs it with the digest release.yml prints in its run
# summary; it fails unless the overlay then renders exactly that reference.
[group('release')]
[doc('Pin the release overlay to an image digest and print the rendered reference (edits a tracked file)')]
release-pin digest: cluster-tools
    sh scripts/release/pin-digest.sh "$1"
