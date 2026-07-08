# Governance gates — making `herd/gates` fail-safe (HERD-194)

herdkit's watcher (`agent-watch.sh`) is the only thing that runs the merge gates: the healthcheck and
the adversarial pre-merge review. In the default single-operator setup those gates are enforced
*inside* the watcher — it simply refuses to auto-merge a PR that hasn't passed them. That is enough
when the watcher is the only path to `main`.

It is **not** enough the moment a human collaborator (or a second operator's seat) also has merge
rights on the repo. A collaborator can click **Merge** in the GitHub UI on a PR the watcher never
blessed, bypassing the gates entirely. The operator decision behind HERD-194 is that collaborators
**keep** their merge rights — so the gate cannot live only inside the watcher. It has to live in
GitHub, where every merge path (UI, API, `gh`, the watcher itself) is subject to it.

## How it works

When `GATE_STATUS=on` (the default), the watcher posts a **commit status** with context `herd/gates`
against each `(pr, head-sha)` as it clears it:

| When | State |
| --- | --- |
| Gates dispatched (watcher started gating this commit) | `pending` |
| Healthcheck reproduced a code error, **or** the review returned BLOCK | `failure` |
| Both gates green (healthcheck + review PASS) | `success` |

Each conclusion is posted **exactly once per `(pr, sha, conclusion)`** (sha-keyed ledger), and the
status is posted **only by a watcher that actually ran the gates**. So a commit that no watcher has
blessed simply has *no* `herd/gates=success` status.

Pair that with a branch-protection rule that **requires** the `herd/gates` check, and the property
becomes fail-safe:

> **Anyone may merge, but nothing ungated can.** A collaborator can still merge — but only a commit a
> watcher has blessed with `herd/gates=success`. An unblessed commit is unmergeable for everyone,
> including the watcher's own `gh pr merge`.

`--match-head-commit` in the watcher's merge path stays as a belt-and-suspenders guard against a race
where a new commit lands between the blessing and the merge.

## One-time branch-protection recipe (operator applies in GitHub settings)

Apply this **once per repo**, in GitHub → **Settings → Branches → Branch protection rules** for your
default branch (e.g. `main`):

1. **Add / edit the rule** for the default branch.
2. Enable **Require status checks to pass before merging**.
3. In the checks search box, add **`herd/gates`** as a required check.
   - It appears in the list once the watcher has posted at least one `herd/gates` status on any PR —
     open a throwaway PR and let a watcher tick run if you don't see it yet, then add it.
4. Enable **Require branches to be up to date before merging** (recommended — it pairs with the
   watcher's stale-base gate and keeps the blessing meaningful).
5. **Do _not_ restrict who can push/merge** ("Restrict who can push to matching branches" /
   restricting merge to specific users). The whole design keeps collaborators' merge rights — the
   *gate* is what's required, not a person. Restricting users would defeat the "anyone may merge"
   half of the property and is unnecessary once `herd/gates` is required.
6. Apply an equivalent rule to any other protected branch a watcher gates.

Equivalent one-shot via the API (adjust `OWNER/REPO` and the branch):

```sh
gh api -X PUT repos/OWNER/REPO/branches/main/protection \
  -H 'Accept: application/vnd.github+json' \
  -f 'required_status_checks[strict]=true' \
  -f 'required_status_checks[checks][][context]=herd/gates' \
  -F 'enforce_admins=false' \
  -F 'required_pull_request_reviews=null' \
  -F 'restrictions=null'
```

(`restrictions=null` = **no** user/team push restrictions — collaborators keep merge rights;
`strict=true` = require up-to-date branches.)

## Turning it off

`GATE_STATUS=off` makes the watcher stop posting statuses (byte-inert: no post, no read). Only do this
on a repo that has **no** `require herd/gates` branch protection — otherwise every PR would be stuck
unmergeable with no watcher able to bless it. If you disable the protection rule, disable
`GATE_STATUS` too (or leave it on; the extra green check is harmless).

## Multiple operators (team mode)

Under `WATCHER_SCOPE=all`, several operators' watchers may see the same shared PR. Before dispatching
its own (expensive) gates, each watcher checks the head sha's existing `herd/gates` status and
**skips** a commit another seat has already blessed — so two seats never both run the gates on the
same commit. The blessing is cross-seat by construction: it lives on the commit in GitHub, not in any
one seat's local ledger.

## Follow-up (out of scope here)

Auto-adopting a *foreign* collaborator's PR into a local worktree so the watcher gates it
automatically is a separate, follow-up change. This PR is surgical: it posts the status and documents
the protection recipe. Until the follow-up lands, a collaborator-authored PR the local watcher does
not track is gated by a watcher only once it's adopted the usual way (`git worktree add`).
