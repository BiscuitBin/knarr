# 03: One reader for the OTP pin and the runtime prefix

**Context:** [Decision 0003](../../../docs/decisions/0003-tool-manager.md) gives the OTP version one owner, the `erlang` pin in `pixi.toml`. Two checkers each parse that pin themselves: `image-check` compares the image's OTP release with it, and `hex-audit` asks OSV about it. The image's runtime prefix, `/opt/knarr/.pixi/envs/runtime`, is likewise a literal in `image-check`, in `runtime-scan` and in both checkers' tests. The owner and the prefix both move in this round, in [07](07-flake-beside-pixi.md) and [09](09-images-from-flake.md). This prefactor leaves each with one place to change.

**What to build:** One function that returns the OTP pin, used by `image-check` and `hex-audit`. One constant for the runtime prefix, used by `image-check`, `runtime-scan` and their tests. Both still return today's pixi values, so behaviour does not change.

**Non-goals:** Changing the owner of the OTP version or the prefix. Touching the Dockerfiles. The tool-directory seam, which is [02](02-tool-directory-seam.md).

**Blocked by:** None (can start immediately)

**MVP critical path:** no.

**Status:** ready-for-agent

- [x] One function under `scripts/` reads the `erlang` pin from `pixi.toml`, and `image-check` and `hex-audit` both call it. Test fixtures that write a sample `pixi.toml` are not readers.
- [x] The absolute prefix `/opt/knarr/.pixi/envs/runtime` is assigned in one place under `scripts/checks/`, and the other checker and the tests import it. Comments, and tests that quote a Dockerfile line, are not counted. The ticket records the `git grep` output.
- [x] The shared reader fails with a named error when the pin is missing or is not an exact version, and a test covers it.
- [x] `just test-checkers-selected packaging audit` passes.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

A prefactor: both values are still pixi's, and no recipe, Dockerfile or pin moved.

- `scripts/checks/_runtime.py` is new, a sibling module the checkers import as they import `_project`. It holds three names:
  - `otp_pin(project)` takes a project directory, reads its `pixi.toml` and returns the exact version the `erlang` pin in `[feature.otp.dependencies]` names, as `29.1.2`. It is the only reader of the pin under `scripts/`.
  - `OtpPinError` is the named error it raises. A `pixi.toml` it cannot read gives the operating system's own message, which names the path. A pin that is absent, or a file that is not TOML, gives `pixi.toml has no erlang pin in [feature.otp]: …`. A pin that is not `==` and one dotted version gives `the erlang pin '…' is not one exact version`.
  - `PREFIX` is `/opt/knarr/.pixi/envs/runtime`, the only assignment of that path under `scripts/`.
- `scripts/checks/hex_audit.py`: `otp_release(pixi_text)` is deleted. `subjects` calls `_runtime.otp_pin(project)` and re-raises `OtpPinError` as `CannotDecideError` with the same text, so `just hex-audit` still prints `hex-audit: cannot decide: …` and exits 2. The two message strings are the ones `otp_release` had, moved unchanged.
- `scripts/checks/image.py`: `main` takes the OTP major from `_runtime.otp_pin(ROOT)`, at the same point as before, ahead of the first `docker` call. `RUNTIME_ENV` is gone and its six uses read `_runtime.PREFIX`.
- `scripts/checks/runtime_scan.py`: `RUNTIME` is gone and its three uses read `_runtime.PREFIX`.
- `scripts/checks/checker_suite.py`: `scripts/checks/_runtime.py` is an input of the `packaging` and `audit` groups and of the `kind` and `worker` clusters, beside each `image.py` entry. `test_runtime.py` belongs to `packaging`.
- Tests: `test_runtime.py` is new, with 20 cases. `test_image.py` and `test_runtime_scan.py` take the prefix from `_runtime.PREFIX`. `test_image.py` gains two cases in which `main` raises `OtpPinError` before it runs `docker`. `test_hex_audit.py` loses the two `otp_release` cases, which moved to `test_runtime.py`, and gains cases that hold `subjects` and `main` to exit 2 with the unchanged messages. `test_checker_suite.py` gains the selection case for `_runtime.py`.

**The two parsers disagreed, and the stricter one was kept.** `hex-audit` refused any pin that was not `==` and one dotted version. `image-check` did not: it stripped a leading `==` and took whatever preceded the first dot. A missing pin was a bare `KeyError`. A range such as `>=29.1.2` became the major `>=29`, and the check ran three containers before it failed with `OTP mismatch: owner=>=29, …`. A pin written `29.1.2`, without `==`, passed. `image-check` now raises `OtpPinError` in all three cases, before any container starts. Its exit status on these is 1 as before, by an uncaught exception, and it also reads `pixi.toml` as UTF-8, which it left to the locale before. With the committed pin, `==29.1.2`, both checkers behave as they did.

One ordering changed in `hex-audit`: when `manifest.toml` is malformed and the pin is also bad, it now names the pin, where before it named the manifest. Both are still exit 2.

The `git grep` output after the change:

```console
$ git grep -n '/opt/knarr/.pixi/envs/runtime' -- scripts
scripts/checks/_runtime.py:24:PREFIX = "/opt/knarr/.pixi/envs/runtime"
scripts/checks/runtime_scan.py:5:ticket 45). So this copies /opt/knarr/.pixi/envs/runtime out of the image into
$ git grep -n 'erlang' -- scripts/checks/image.py scripts/checks/hex_audit.py
scripts/checks/hex_audit.py:9:- the `erlang` pin in pixi.toml, as the `OTP-<version>` tag of
scripts/checks/hex_audit.py:10:    github.com/erlang/otp, in OSV's `GIT` ecosystem, which is where OSV records
scripts/checks/hex_audit.py:37:OTP_REPOSITORY = "https://github.com/erlang/otp"
scripts/checks/image.py:117:    erlang and openssl, writing only to the /tmp tmpfs."""
scripts/checks/image.py:373:        "io:put_chars(erlang:system_info(otp_release)), halt().",
```

The first has one assignment and one docstring line, which is a comment. The second has no line that reads the pin: the one `["erlang"]` lookup under `scripts/` is `scripts/checks/_runtime.py:38`.

### What was verified, and what was not

- Red, then green. With the tests written and no `_runtime.py`, the four test modules failed to import it and `checker_suite.py` refused to run: `test ownership mismatch: ['scripts/checks/tests/test_runtime.py']`. With the module written and no checker changed, 7 cases failed and 110 passed: the three that require `hex-audit`'s refusal to come from `OtpPinError`, the two for `image.main`, and the ownership and selection cases. After the checkers and the table changed, all passed.
- `just test-checkers-selected packaging audit`: 107 passed. `just test-checkers-selected policy packaging audit`, which adds `test_checker_suite.py`: 276 passed.
- Box 3 is covered in `test_runtime.py`: nine pins that are not exact, five files with no pin, a missing `pixi.toml` and one that is not UTF-8, each asserting `OtpPinError` and its message.
- `test_both_images_ship_the_runtime_at_the_prefix` is a new guard, not a moved one: both Dockerfiles must contain `COPY --from=build` with `PREFIX` as source and destination. Before, only `just image-check` on a built image tied the checkers' prefix to the Dockerfiles.
- Each checker still runs as a script with the sibling import, on paths that stop before the network and Docker: `hex_audit.py` on a directory whose pin is `>=29.1.2` printed `hex-audit: cannot decide: the erlang pin '>=29.1.2' is not one exact version` and exited 2; `runtime_scan.py` and `image.py` with no argument printed their usage.
- `just lint`: every hook passed, ruff among them.
- `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes.
- Not run, because they need the network or Docker and this ticket had no authorization for either: `just hex-audit`, `just image-check`, `just fake-worker-image-check` and `just runtime-scan`. Their changed lines are covered by the injected-`docker` and injected-`post` tests only.
- Not pushed, so `ci.yml` has not run on this branch.

### What later tickets need

- **07 (flake beside pixi)** changes one function body, `otp_pin` in `scripts/checks/_runtime.py`, to read the held-versions file. Its two callers, `image.main` and `hex_audit.subjects`, pass a project directory and need no change. What follows from it:
  - Both `OtpPinError` messages name `pixi.toml` and `[feature.otp]`. They are asserted in `test_runtime.py`, in `test_hex_audit.py` (`test_main_cannot_decide_without_an_exact_otp_pin`) and in `test_image.py` (`test_main_refuses_an_otp_pin_that_is_not_one_exact_version`).
  - Those three test modules write a sample `pixi.toml` as the reader's input, so each fixture changes to the new file.
  - The `==` in the pattern is pixi's spelling of an exact pin. Keep the return value a bare dotted version: `hex_audit.py` builds the `OTP-` tag from it and `image.py` takes the major before the first dot.
  - 07's policy test that holds `pixi.toml` equal to the held-versions file needs the pixi parsing `otp_pin` has today. Move it into that test, so `scripts/` outside the tests still has one reader.
  - `pixi.*` is in `checker_suite.py`'s `SHARED`, so today a pin change runs every group. The held-versions file is not there. Register it in `SHARED`, or as an input of `packaging` and `audit` and of the `kind` and `worker` clusters.
  - The words "the `erlang` pin in pixi.toml" are in `hex_audit.py`'s module docstring, in `_runtime.py`'s docstrings and in the `hex-audit` recipe's description.
- **09 (images from the flake)** changes one constant, `PREFIX` in `scripts/checks/_runtime.py`. `image.py`, `runtime_scan.py`, `test_image.py` and `test_runtime_scan.py` follow it with no edit. What does not follow from the value alone:
  - `test_both_images_ship_the_runtime_at_the_prefix` fails until both Dockerfiles copy the runtime to the new prefix. It expects the `COPY --from=build` line with the prefix as source and destination, so if the final stage receives the closure from a different path the assertion changes with it.
  - `image.verify_runtime_environment` assumes a conda environment at the prefix: it requires `conda-meta/`, and checks that `bin/perl` and `conda-meta/perl-*.json` are absent. The TLS check passes the prefix to `.scratch/bootstrap/evidence/01/tls/run.sh`, which puts its `bin/` first on `PATH` and expects `openssl` and `escript` there.
  - `runtime_scan.py` copies the prefix out and requires grype's `conda-meta-cataloger` to catalogue a package. That is 11's, and it is why no release happens between 09 and 11.
  - `runtime_scan.py`'s module docstring, line 5, spells the prefix in prose. `test_prune_runtime.py` quotes the Dockerfile's relative `.pixi/envs/runtime` and does not use the constant.
- **11 (runtime scan reads the Nix closure)** reads the prefix as `_runtime.PREFIX`; `runtime_scan.RUNTIME` no longer exists.
