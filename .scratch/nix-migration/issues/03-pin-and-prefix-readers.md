# 03: One reader for the OTP pin and the runtime prefix

**Context:** [Decision 0003](../../../docs/decisions/0003-tool-manager.md) gives the OTP version one owner, the `erlang` pin in `pixi.toml`. Two checkers each parse that pin themselves: `image-check` compares the image's OTP release with it, and `hex-audit` asks OSV about it. The image's runtime prefix, `/opt/knarr/.pixi/envs/runtime`, is likewise a literal in `image-check`, in `runtime-scan` and in both checkers' tests. The owner and the prefix both move in this round, in [07](07-flake-beside-pixi.md) and [09](09-images-from-flake.md). This prefactor leaves each with one place to change.

**What to build:** One function that returns the OTP pin, used by `image-check` and `hex-audit`. One constant for the runtime prefix, used by `image-check`, `runtime-scan` and their tests. Both still return today's pixi values, so behaviour does not change.

**Non-goals:** Changing the owner of the OTP version or the prefix. Touching the Dockerfiles. The tool-directory seam, which is [02](02-tool-directory-seam.md).

**Blocked by:** None (can start immediately)

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] One function under `scripts/` reads the `erlang` pin from `pixi.toml`, and `image-check` and `hex-audit` both call it. Test fixtures that write a sample `pixi.toml` are not readers.
- [ ] The absolute prefix `/opt/knarr/.pixi/envs/runtime` is assigned in one place under `scripts/checks/`, and the other checker and the tests import it. Comments, and tests that quote a Dockerfile line, are not counted. The ticket records the `git grep` output.
- [ ] The shared reader fails with a named error when the pin is missing or is not an exact version, and a test covers it.
- [ ] `just test-checkers-selected packaging audit` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
