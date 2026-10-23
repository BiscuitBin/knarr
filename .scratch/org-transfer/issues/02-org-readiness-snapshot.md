# 02: Org readiness and settings snapshot

**Context:** [Decision 0016](01-biscuitbin-decision.md) moves knarr to `github.com/biscuitbin/knarr` by GitHub's repository transfer. The transfer is expected to carry the repository's settings, but nothing assumes it. This ticket records what the repository has today, so that [03](03-transfer-repository.md) can record it again after the transfer and diff the two. It also checks that the org will let knarr's workflows run and publish before anything moves.

**What to build:** A settings snapshot of `steven-cutting/knarr`, taken with `gh api` by a script kept beside its output, and the maintainer's check of the org's settings.

**Non-goals:** The transfer itself (03). Changing a repository or org setting. Recording a secret's value: only names are recorded.

**Blocked by:** None (can start immediately).

**MVP critical path:** no.

**Status:** needs-human

- [x] **Authorization required:** `gh` and the network. `.scratch/org-transfer/evidence/02/settings.sh` writes `settings.txt`, which records, from the repository as it is now:
  - the rulesets, with each one's target, conditions, rules and bypass list, and the branch protection on `main` with its required status checks by name;
  - the `release` environment: its required reviewers, its deployment branch and tag policy, and its protection rules;
  - the names of the repository's secrets and variables, and of the `release` environment's, never their values;
  - the Actions permissions: whether Actions is enabled, the allowed-actions policy, and the default `GITHUB_TOKEN` permissions;
  - private vulnerability reporting, and the security features (Dependabot alerts, secret scanning, push protection, code scanning default setup);
  - the GitHub App installations with access to the repository, among them Renovate;
  - the repository's visibility, default branch, merge settings and topics;
  - the repository's labels by name, among them `keda-e2e` and `cluster-s1`, which gate the cluster workflows.

  Bootstrap ticket 37's [settings.sh](../../bootstrap/evidence/37/settings.sh) is the starting shape. The script reads the same endpoints with the owner as a parameter, so 03 reruns it unchanged against `biscuitbin`.
- [x] The maintainer checks the org, and `.scratch/org-transfer/evidence/02/org.txt` records what they saw:
  - they are an owner of `biscuitbin`;
  - the org's Actions policy allows every action the workflows use, each pinned by SHA (list them from `.github/workflows/` and `.github/actions/`);
  - the org's default workflow permissions allow `packages: write` where a workflow asks for it;
  - members can create **public** packages;
  - the Renovate app is installed on the org, or will be granted knarr after 03;
  - the org's two-factor requirement and base permissions do not block the maintainer.
- [x] Anything the org check found blocking is fixed, or recorded here as a step 03 takes right after the transfer.

## Hand-back notes

Done on 2026-10-22 (UTC) with the maintainer. [The evidence README](../evidence/02/README.md) indexes the scripts and transcripts, summarizes what they show, and lists every network action authorized.

**What changed:** `.scratch/org-transfer/evidence/02/` was added, holding `lib.sh`, `settings.sh`, `settings.txt`, `org.sh`, `org.txt` and `README.md`, and this ticket was updated. No other tracked file changed, and no repository or org setting changed.

**What was verified:**

- Before any network call, both scripts ran against a stub `gh` with canned answers. The stub checked that 403, 404 and 204 answers are recorded and the run continues, and that no response, a 401, a 500, a rate limit or a second page stops it. It also checked that a variable's value never reaches the output. After PR review, it also checked that an app reaching the repository under a differently cased owner login is recorded as `yes`. `shellcheck` 0.11.0 is clean, with and without `-x`.
- [settings.txt](../evidence/02/settings.txt) has every section this ticket lists. `main` requires `check` through classic branch protection. The `release tags` ruleset protects `refs/tags/v*`. `release` requires the reviewer `User:steven-cutting` and has no deployment branch or tag policy. There are no secrets or variables. Both labels are present.
- In [org.txt](../evidence/02/org.txt), the maintainer's role in `biscuitbin` is `admin` (owner). The base permission is `read`, 2FA is not required, and no app is installed. The UI shows that all actions are allowed (so `actions/checkout` and `prefix-dev/setup-pixi`, each pinned by SHA, can run), that the default workflow permissions are read, and that members can create public packages.

**What the org check found blocking:** nothing. The steps for 03 are:

- `release` has no deployment branch or tag policy today (`deployment_branch_policy: null`). 03's "deployment branch and tag policy unchanged" therefore means it is still `null`. Adding a policy is a separate decision.
- No app reaches knarr, Renovate included. [Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md) holds Renovate uninstalled until bootstrap ticket [44](../../bootstrap/issues/44-renovate-activation.md), so the transfer has no access to lose, and 03 has nothing to restore. Ticket 44, if it runs after 03, installs the Mend app on `biscuitbin`, limited to `knarr`. That needs an org owner, which the maintainer is.
- The `biscuitbin` org is on the free plan, which does not enforce org rulesets. knarr's tag ruleset is a repository ruleset, which the free plan enforces on public repositories. 03's diff shows whether it carried.
- gh's token lacks `admin:org`, so `org.sh` reads the org's Actions policy as 403. Run `gh auth refresh -s admin:org` if 03 wants them from the API.

**What each later ticket needs:**

- **03:** rerun `sh .scratch/org-transfer/evidence/02/settings.sh biscuitbin`. The expected differences are the header, `full_name`, `owner`, `owner_type` (now `Organization`), possibly the ruleset id in its heading, and the app section, where `orgs/biscuitbin/installations` now answers 200. Every other difference is a finding. The README's rerun block has the commands.
- **04 and 05:** nothing from here beyond the public-package check above. `release.yml`'s explicit `packages: write` overrides the org's read default.
