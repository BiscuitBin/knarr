# 02: Org readiness and settings snapshot

**Context:** [Decision 0016](01-biscuitbin-decision.md) moves knarr to `github.com/biscuitbin/knarr` by GitHub's repository transfer. The transfer is expected to carry the repository's settings, but nothing assumes it. This ticket records what the repository has today, so that [03](03-transfer-repository.md) can record it again after the transfer and diff the two. It also checks that the org will let knarr's workflows run and publish before anything moves.

**What to build:** A settings snapshot of `steven-cutting/knarr`, taken with `gh api` by a script kept beside its output, and the maintainer's check of the org's settings.

**Non-goals:** The transfer itself (03). Changing a repository or org setting. Recording a secret's value: only names are recorded.

**Blocked by:** None (can start immediately).

**MVP critical path:** no.

**Status:** needs-human

- [ ] **Authorization required:** `gh` and the network. `.scratch/org-transfer/evidence/02/settings.sh` writes `settings.txt`, which records, from the repository as it is now:
  - the rulesets, with each one's target, conditions, rules and bypass list, and the branch protection on `main` with its required status checks by name;
  - the `release` environment: its required reviewers, its deployment branch and tag policy, and its protection rules;
  - the names of the repository's secrets and variables, and of the `release` environment's, never their values;
  - the Actions permissions: whether Actions is enabled, the allowed-actions policy, and the default `GITHUB_TOKEN` permissions;
  - private vulnerability reporting, and the security features (Dependabot alerts, secret scanning, push protection, code scanning default setup);
  - the GitHub App installations with access to the repository, among them Renovate;
  - the repository's visibility, default branch, merge settings and topics.

  Bootstrap ticket 37's [settings.sh](../../bootstrap/evidence/37/settings.sh) is the starting shape. The script reads the same endpoints with the owner as a parameter, so 03 reruns it unchanged against `biscuitbin`.
- [ ] The maintainer checks the org, and `.scratch/org-transfer/evidence/02/org.txt` records what they saw:
  - they are an owner of `biscuitbin`;
  - the org's Actions policy allows every action the workflows use, each pinned by SHA (list them from `.github/workflows/` and `.github/actions/`);
  - the org's default workflow permissions allow `packages: write` where a workflow asks for it;
  - members can create **public** packages;
  - the Renovate app is installed on the org, or will be granted knarr after 03;
  - the org's two-factor requirement and base permissions do not block the maintainer.
- [ ] Anything the org check found blocking is fixed, or recorded here as a step 03 takes right after the transfer.

## Hand-back notes
