# Org-transfer ticket 02 evidence

Evidence for [ticket 02](../../issues/02-org-readiness-snapshot.md): the settings of `steven-cutting/knarr` before [Decision 0016](../../../../docs/decisions/0016-biscuitbin-org.md)'s transfer, and the maintainer's check of the `biscuitbin` org. Gathered on 2026-10-22 (UTC) with gh 2.100.0 and jq 1.7.1, logged in as `steven-cutting` with the token scopes `admin:public_key`, `gist`, `read:org`, `repo` and `workflow`. Every step that left the worktree was authorized by the maintainer, one action at a time.

The scripts record and do not judge, unlike bootstrap ticket 37's [settings.sh](../../../bootstrap/evidence/37/settings.sh), whose shape they keep. Each section is one `gh api` GET, headed `== <what>: gh api <endpoint>`, then its HTTP status, then the answer projected to the fields that describe the setting, keys sorted, so that [03](../../issues/03-transfer-repository.md)'s diff shows settings rather than object identities. Named projections leave out ids, and `scrub` drops `id`, `node_id`, URL and timestamp keys. Two kinds of id are kept on purpose: the ruleset id in its section heading, and the app and actor ids inside a rule (`app_id` 15368 is GitHub Actions), which name the same app under either owner. A 403 or 404 is an answer: it is recorded with GitHub's message, and the script goes on. A script stops when the repository or org itself does not answer 200, when there is no response (gh not logged in, no network), on any other status, on a rate limit, or when a list has a second page.

- [lib.sh](lib.sh) holds `get`, which makes every read, and the header both scripts print.
- [settings.sh](settings.sh) `<owner>` reads `<owner>/knarr`: the repository's visibility, merge settings, topics and `security_and_analysis`; each ruleset in full; the branch protection on `main`; the `release` environment, with its reviewers by login, and its branch and tag policies when they are custom; the names of the repository's and the environment's secrets and variables, never a value (the variables endpoints return values, and the projection drops them); the Actions permissions; the security features; the app installations; and the labels. [settings.txt](settings.txt) is its one run against `steven-cutting`, at 23:18Z.
- [org.sh](org.sh) `<org>` reads the maintainer's membership, the org's base permission and two-factor requirement, its Actions policy and default workflow permissions, its rulesets and its app installations. It then lists, from the worktree and with no network, the actions the workflows use. [org.txt](org.txt) is its one run against `biscuitbin`, at 23:18Z, followed by what the maintainer read in the UI and notes, each dated.

What the record shows:

- `main` is protected by classic branch protection, not a ruleset. It requires the status check `check` (app 15368, GitHub Actions), not strict, with no approving review required and no admin enforcement.
- The one ruleset is `release tags`: `refs/tags/v*`, rules `deletion` and `update`, active, no bypass actors.
- `release` has one protection rule, required reviewers `User:steven-cutting` with self-review allowed, and no deployment branch policy (`null`). Administrators can bypass it.
- No secret or variable exists, in the repository or in `release`.
- Actions allows all actions with no SHA-pinning requirement. Workflows get read permissions by default.
- Private vulnerability reporting, Dependabot alerts, secret scanning and push protection are on. Dependabot security updates are off, and code scanning default setup is `not-configured`.
- No app reaches the repository. `user/installations` answers only to a GitHub App's token (403), and the owner is a user, so the org listing is 404. The maintainer confirmed in the UI that the list is empty. Renovate is held uninstalled by [Decision 0014](../../../../docs/decisions/0014-dependency-updates-and-audit.md) until bootstrap ticket 44.
- The labels include `keda-e2e` and `cluster-s1`.
- In `biscuitbin`, the maintainer's role is `admin`, which is an owner. The base permission is `read`, two-factor authentication is not required, and no app is installed. The free plan does not enforce org rulesets, and none exist. The UI shows that all actions are allowed, the default workflow permissions are read, and members can create public packages.

## Network the maintainer authorized for this ticket

On 2026-10-22 (UTC), each separately: `just initialize`, run by the maintainer; `gh auth status` and one `settings.sh steven-cutting` run; one `org.sh biscuitbin` run. Then the push of this branch and its pull request, when authorized.

The scripts were first run against a stub `gh` in `ai_tmp/`, with canned 200, 204, 403 and 404 answers, a missing response, a 401, a 500, a rate limit and a second page, and variable values that must not reach the output. That stub is scratch and is not part of the change.

After both runs, the review of this branch made three changes to the scripts. `settings.sh` and `org.sh` now stop unless the repository or org read answers 200. The environment projection reads missing protection rules as none. `gh --version` and the workflow `grep` are now checked on their own, not through a pipeline. On the answers recorded here, none of these changes alters a line of output, so the transcripts were not retaken. The stub tests were rerun after the changes.

## Rerun

Every run reaches the network and needs authorization. Ticket 03 reruns `settings.sh` unchanged after the transfer and diffs the two. The header's date, gh and repository lines, `full_name`, `owner`, `owner_type` and the ruleset id in a heading are expected to differ:

```sh
E=.scratch/org-transfer/evidence/02
# This record was `sh $E/settings.sh steven-cutting > $E/settings.txt 2>&1`.
# After the transfer that owner redirects to biscuitbin, so it is not rerun.
T=.scratch/org-transfer/evidence/03
mkdir -p $T
sh $E/settings.sh biscuitbin >| $T/settings.txt 2>&1
diff $E/settings.txt $T/settings.txt >| $T/settings.diff
sh $E/org.sh biscuitbin >| ai_tmp/org.txt 2>&1   # a fresh org read; the UI block is added by hand
```

The org's Actions policy endpoints need `admin:org`, which gh's token lacks. A rerun records them as 403 again unless the token is refreshed with `gh auth refresh -s admin:org`.
