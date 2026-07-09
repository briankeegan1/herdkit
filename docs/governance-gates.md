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
| Both gates green (healthcheck + review PASS) | `success` |
| A gate fails (healthcheck code error, or review BLOCK) | *(nothing posted)* |

The watcher posts **only `success`** — it never posts a non-passing (`pending`/`failure`) status. A
non-passing commit status flips a `CLEAN` sha to `mergeStateStatus=UNSTABLE`, which would strand the PR
out of the merge loop (and silently break the block/override/auto-refix paths) in the default
*unprotected* config. The fail-safe below needs only the **absence of `success`**: a PR the watcher did
not bless simply has no `herd/gates=success`, and GitHub renders the missing *required* check as
"Expected / waiting" on its own. A failed gate therefore posts nothing — the PR's red row and review
comment come from the watcher console and the review gate, not from a commit status.

The blessing is posted **exactly once per `(pr, sha)`** (sha-keyed ledger), and **only by a watcher that
actually ran the gates**. So a commit that no watcher has blessed simply has *no* `herd/gates=success`
status.

Pair that with a branch-protection rule that **requires** the `herd/gates` check, and the property
becomes fail-safe:

> **Anyone may merge, but nothing ungated can.** A collaborator can still merge — but only a commit a
> watcher has blessed with `herd/gates=success`. An unblessed commit is unmergeable for everyone,
> including the watcher's own `gh pr merge`.

`--match-head-commit` in the watcher's merge path stays as a belt-and-suspenders guard against a race
where a new commit lands between the blessing and the merge.

### No bootstrap deadlock

Requiring `herd/gates` creates an obvious chicken-and-egg: a PR whose head sha has no
`herd/gates=success` reports `mergeStateStatus=BLOCKED` (a missing *required* check is not `CLEAN`),
and the watcher's merge path only acts on `CLEAN` PRs — so nothing would ever post the status that
clears the block. The watcher avoids this by treating a **`BLOCKED` PR it has not yet blessed for this
sha** as *gate-eligible*: it runs the gates and posts `herd/gates` **without** merging (the merge still
requires `CLEAN`). Once the blessing lands GitHub recomputes the PR to `CLEAN`, and a later tick takes
the normal merge path. So applying the protection rule to a repo with open PRs just blesses them on the
next tick — it never strands them. (A PR that stays `BLOCKED` for some *other* reason — a required
human review — is gated at most once per sha, then simply waits.)

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

### API alternative (read-merge-write — **preserves existing rules**)

The UI steps above are the simple path. If you must script it, do **not** naively
`PUT …/protection` with a hand-built body: that endpoint is a **full replace**, so a body that omits
your existing required reviews / other required checks / push restrictions **silently strips them**.
Instead **read** the current protection, **merge** `herd/gates` into its existing required checks, and
**write** the reconstructed object back — preserving everything else verbatim. (GET and PUT use
different shapes for reviews/restrictions/toggles, so the `jq` below transforms each field to its PUT
form; it is a no-op-safe upsert — re-running never double-adds `herd/gates`, and it also works on a
branch whose protection has no status checks yet.)

```sh
OWNER=your-org REPO=your-repo BRANCH=main   # adjust

# 1. READ current protection (empty file if the branch has no protection yet — see note below).
gh api "repos/$OWNER/$REPO/branches/$BRANCH/protection" > /tmp/prot.json

# 2. MERGE herd/gates into the existing required status checks, preserving every other rule.
jq '{
  required_status_checks: (
    if .required_status_checks == null
    then { strict: false, checks: [ { context: "herd/gates" } ] }
    else { strict: .required_status_checks.strict,
           checks: ( ( .required_status_checks.checks
                       // ( .required_status_checks.contexts // [] | map({context: .})) )
                     + [ { context: "herd/gates" } ] | unique_by(.context) ) }
    end
  ),
  enforce_admins: (.enforce_admins.enabled // false),
  required_pull_request_reviews: (
    if .required_pull_request_reviews == null then null
    else .required_pull_request_reviews as $r
      | { dismiss_stale_reviews: $r.dismiss_stale_reviews,
          require_code_owner_reviews: $r.require_code_owner_reviews,
          required_approving_review_count: $r.required_approving_review_count,
          require_last_push_approval: ($r.require_last_push_approval // false) }
        + ( if $r.dismissal_restrictions then { dismissal_restrictions: {
              users: [ $r.dismissal_restrictions.users[]?.login ],
              teams: [ $r.dismissal_restrictions.teams[]?.slug ],
              apps:  [ $r.dismissal_restrictions.apps[]?.slug ] } } else {} end )
        + ( if $r.bypass_pull_request_allowances then { bypass_pull_request_allowances: {
              users: [ $r.bypass_pull_request_allowances.users[]?.login ],
              teams: [ $r.bypass_pull_request_allowances.teams[]?.slug ],
              apps:  [ $r.bypass_pull_request_allowances.apps[]?.slug ] } } else {} end )
    end
  ),
  restrictions: (
    if .restrictions == null then null
    else { users: [ .restrictions.users[]?.login ],
           teams: [ .restrictions.teams[]?.slug ],
           apps:  [ .restrictions.apps[]?.slug ] }
    end
  ),
  required_linear_history: (.required_linear_history.enabled // false),
  allow_force_pushes: (.allow_force_pushes.enabled // false),
  allow_deletions: (.allow_deletions.enabled // false),
  block_creations: (.block_creations.enabled // false),
  required_conversation_resolution: (.required_conversation_resolution.enabled // false),
  lock_branch: (.lock_branch.enabled // false),
  allow_fork_syncing: (.allow_fork_syncing.enabled // false)
}' /tmp/prot.json > /tmp/prot.new.json

# 3. Review the diff, THEN write it back.
diff <(jq -S . /tmp/prot.json) <(jq -S . /tmp/prot.new.json)   # sanity-check what changes
gh api -X PUT "repos/$OWNER/$REPO/branches/$BRANCH/protection" --input /tmp/prot.new.json
```

Notes:
- **Branch not protected yet?** Step 1 returns `404` and writes an error object, not a protection
  object. In that case set up protection in the **UI** first (it's the simpler from-scratch path), then
  the script above is only needed if you later automate additions.
- This keeps **`restrictions` exactly as they were** — it does *not* impose push restrictions (the
  design keeps collaborators' merge rights; the gate is the required check, not a person). If your repo
  has none, `restrictions` stays `null`.
- It does **not** flip `strict` (require-up-to-date). Enable *Require branches to be up to date* in the
  UI (recommended) or add `.required_status_checks.strict = true` in the `jq`.

## Turning it off

`GATE_STATUS=off` makes the watcher stop posting statuses (byte-inert: no post, no read). Only do this
on a repo that has **no** `require herd/gates` branch protection — otherwise every PR would be stuck
unmergeable with no watcher able to bless it. If you disable the protection rule, disable
`GATE_STATUS` too (or leave it on; the extra green check is harmless).

## Multiple operators (team mode)

Under `WATCHER_SCOPE=all`, several operators' watchers may see the same shared PR. Before dispatching
its own (expensive) gates, each watcher checks the head sha's existing `herd/gates` status and does not
re-gate a commit another seat has already blessed — so two seats don't both run the gates on the same
commit. The blessing is cross-seat by construction: it lives on the commit in GitHub, not in any one
seat's local ledger. (A seat that observes a blessing it hasn't recorded heals its own ledger and
proceeds to merge as normal — a local ledger loss never strands an owned, already-blessed PR.)

## Trust model

The gate assumes **write-scoped tokens are trusted**. Any actor with `repo:status` (or `statuses:write`)
on the repo can post a `herd/gates=success` status directly and thereby bless a commit without a
watcher having run the gates. Branch protection's required-status-check enforcement is only as strong as
who can post that context. Keep status-write scope limited to the operators' watcher tokens; do not hand
`repo:status` to untrusted collaborators or third-party apps. (This is the same trust boundary as any
required-status-check gate on GitHub — the check is a claim by whoever can write it.)

## Follow-up (out of scope here)

Auto-adopting a *foreign* collaborator's PR into a local worktree so the watcher gates it
automatically is a separate, follow-up change. This PR is surgical: it posts the status and documents
the protection recipe. Until the follow-up lands, a collaborator-authored PR the local watcher does
not track is gated by a watcher only once it's adopted the usual way (`git worktree add`).
