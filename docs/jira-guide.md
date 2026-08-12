# Run your agent fleet against Jira

herdkit's work tracker is pluggable (`SCRIBE_BACKEND`). Set it to `jira` and your **Jira Cloud
project becomes the queue the fleet reads from and writes back to**: filed work becomes a Jira
issue, a spawn claims that issue (assignee + *In Progress*), the builder's PR carries the issue key,
and a merge transitions it to *Done* with the PR linked in a comment. No BACKLOG.md, no second
tracker to keep in sync, nothing for a human to copy between systems.

Everything below is grounded in the shipped adapter, `scripts/herd/backends/jira.sh`, and the
guided switch in `bin/herd`. Nothing here is aspirational — what the adapter does **not** do is in
[Limits and caveats](#limits-and-caveats).

---

## Before you start

| requirement | why |
|---|---|
| A **Jira Cloud** site | the adapter speaks Jira Cloud REST **v3** (`/rest/api/3/…`, including the `/search/jql` search endpoint). Jira Server / Data Center is **not** supported |
| An **Atlassian API token** + the account email | the adapter basic-auths with `email:token` on every call |
| Project permissions for that account | *Browse projects*, *Create issues*, *Add comments*, *Transition issues*, *Assign issues* — and *Delete comments* if you use planned-work markers (`herd backlog unqueue`) |
| `curl` and `python3` on `PATH` | every round-trip goes through `curl`; every response is parsed with `python3` |
| An initialized herdkit project | i.e. a `.herd/config` exists (`herd init`) |

> **`herd init` does not wire Jira up.** Answering "Jira" to init's tracker question prints a
> *coming soon* warning and falls back to the file backend. The guided switch below is the
> supported path — run `herd init` first (file backend), then switch.

---

## 1. Setup — one guided command

```sh
herd backend switch jira
```

That command is the whole setup, and it runs in gate order:

1. **Engine handshake.** A switch rewrites `.herd/config` and (with `--migrate`) moves every open
   item between trackers, so an engine below the project's committed `ENGINE_MIN` refuses here —
   before any preflight or write.
2. **Preflight (nothing has changed yet).** Missing credentials are prompted for **on a tty** —
   base URL, account email, then the token with hidden input — and appended to `.herd/secrets`,
   which is created `chmod 600` and added to `.gitignore` if it isn't already. Then a **live
   round-trip** proves them: `GET /rest/api/3/myself` must return an `accountId`, and you'll see

   ```
   ✓ Jira API reachable (myself check passed)
   ```

   A failed preflight **changes nothing** — no config write, no migration.
3. **Flip.** `SCRIBE_BACKEND=jira` is written through the validated `herd config set` path, so it
   inherits key/value validation, the stale-drainer warning, and the coordinator-skill re-render.
4. **Migrate (optional).** `--migrate` replays the old backend's open items into Jira via the same
   create path new items use. It is idempotent — an item whose normalized title already appears in
   Jira's open list is skipped — and each migrated title carries a `(migrated from file)`
   provenance suffix. `--no-migrate` skips it; on a tty with neither flag you're asked.
5. **Retire the old backend's pending reconcile intents.** A merged PR whose tracker item was never
   confirmed Done leaves a "reconcile pending" console row, and the sweep can heal that row only
   through the *active* backend — so a ref minted under the old backend would nag forever once
   `SCRIBE_BACKEND` flips. The switch walks the last 50 landed PRs and, **while the old backend is
   still fully configured**, either completes the mark-shipped there (ledgering the ref Done) or
   retires it with a `tracker_reconcile_retired` journal event so no future sweep re-probes it. It
   is bounded and fail-soft: a row that cannot be probed just stays pending for the next sweep, and
   this step never fails the switch.
6. **Freeze the old file.** Leaving the `file` backend stamps `BACKLOG.md` with a dated
   **FROZEN ARCHIVE** banner pointing readers at `herd backlog`, so the file reads as history to
   everyone who opens it later.
7. **Restart + journal.** The backlog viewer pane is restarted (it binds the backend at process
   start) and a `backend_switched` event is journaled.

**Off a tty** (CI, a headless seat) there is no prompt: the switch dies with
`JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN missing — add them to <…>/.herd/secrets (gitignored)
and re-run; nothing was changed`. Write the credentials yourself first (next section), then run
`herd backend switch jira --no-migrate`.

### Credentials live in `.herd/secrets` — never in config

`.herd/secrets` is gitignored and sourced as shell assignments:

```sh
# .herd/secrets  (chmod 600, gitignored — NEVER .herd/config, which is committed)
JIRA_BASE_URL="https://your-site.atlassian.net"
JIRA_EMAIL="you@example.com"
JIRA_API_TOKEN="<atlassian-api-token>"

# optional
JIRA_PROJECT_KEY="ENG"     # scope new issues + the open list to one project
JIRA_ISSUE_TYPE="Task"     # issue type new items are created as (default: Task)
```

Every adapter operation checks all three required values first and, if any is missing, exits
loudly with `jira backend: … not set — add to .herd/secrets (gitignored), NOT .herd/config
(or switch SCRIBE_BACKEND)`. Credentials are never echoed, never written to `.herd/config`, and
never land in a generated or committed file.

### Scoping to one project

`JIRA_PROJECT_KEY` is optional but recommended:

| set | unset |
|---|---|
| new issues file into that project; the open list is `project = "<KEY>" AND statusCategory != Done` | new issues file into **the first project the token can see**; the open list spans **every** project the token can see |

It scopes only the operations that carry no identifier (list-open, create). It deliberately does
**not** scope *resolution*: Jira keys are unique site-wide, so a reference to `OPS-4` resolves
against `OPS` even when the project key is `ENG` — a cross-project reference is never mislabeled by
your configured project.

If the token can see no project at all, a create reports no change with
`jira backend: no project available to create the issue in (set JIRA_PROJECT_KEY in .herd/secrets)`.

---

## 2. The lifecycle: issue → builder → PR → Done

### 2.1 Work is filed → a Jira issue

Whatever files work (the coordinator's scribe drainer, `herd report`, a watcher reconcile request)
dispatches through the backend's create path: `POST /rest/api/3/issue` into `JIRA_PROJECT_KEY` as
`JIRA_ISSUE_TYPE` (default `Task`), with

- **summary** — a *short* title derived from the request's first line: used verbatim when it's
  ≤100 chars, otherwise reduced to its first clause (split on ` — `, `: `, or `. `) and hard-capped
  at 100 with an ellipsis;
- **description** — the **full** request text, written as an Atlassian Document Format (ADF)
  paragraph. The title summarizes; it never replaces the body.

The new issue's browse URL comes back on success, and the receipt names the minted key (`ENG-12`),
so the filing operator sees the identifier immediately. A create Jira **refuses** is reported as no
change — and with `CREATE_SELFHEAL` on (the default) the request is diverted into the durable retry
queue rather than silently consumed.

### 2.2 See the queue

```sh
herd backlog                 # one "#ENG-12 <summary>" line per open issue, oldest first
herd backlog --rich          # TSV: key, status category, status name, summary, description, assignee, URL
herd backlog show ENG-12     # full detail: live status, summary, untruncated description, URL, updated date
herd backlog browse          # fzf picker over the open list with a live detail preview
```

**Open** means `statusCategory != Done` — Jira's three categories are *new* (To Do),
*indeterminate* (In Progress) and *done* (Done / Won't Do / Cancelled), so anything not folded into
Done is live work. `--rich` sorts in-progress items above not-started ones and flattens the ADF
description to a single whitespace-collapsed line (capped at 280 chars) so the TSV shape can never
be corrupted by field content; the trailing URL is what makes the backlog pane's id chip a
clickable hyperlink.

### 2.3 Publish plan-time intent (multi-operator)

Before a second operator can grab the same issue, publish a marker:

```sh
herd backlog queue ENG-12 --after ENG-9   # 📌 comment: "queued by <who>: sequenced after ENG-9"
herd backlog queued                       # list live markers; >24h old are flagged ADVISORY
herd backlog unqueue ENG-12               # delete the marker comment(s)
```

On Jira the marker is a comment on the issue. It is advisory, never a gate — an unresolvable ref or
a transport hiccup is a no-change, never a hard error.

### 2.4 Spawn claims the issue

With `CLAIM_REQUIRED=on`, the builder lanes claim the item **synchronously before any worktree or
agent exists**. On Jira a claim is:

1. read the token's own user (`GET /rest/api/3/myself`) — the Jira-side claimant identity is the
   **API token's account**, not a login string;
2. read the issue's current status + assignee;
3. **abort** if it is already Done, or assigned to a *different* account (the spawn fails loudly
   with the blocking assignee named — no worktree, no agent);
4. otherwise assign it to the token's own account and transition it into an *indeterminate* status,
   preferring one named **In Progress**;
5. **re-read** the assignee to verify the claim landed on us and not on a racer.

An already-ours, already-started issue reads as a self-claim and proceeds. An unreachable backend
fails soft (warn + proceed), so a solo operator is never hard-blocked.

### 2.5 The builder's PR carries the key

The spawn threads the tracker ref into the builder's task spec, which requires an explicit

```
Refs: ENG-12
```

line in the PR body. That line is what links the merge back to the issue.

### 2.6 Merge → Done

After the watcher's gates pass and the PR merges, reconcile resolves the PR's `Refs:` value and
transitions the issue:

- it reads the issue's **available transitions**, picks one whose destination lands in the *done*
  category — preferring a transition or destination status literally named **Done**, so a project
  with both *Done* and *Cancelled* doesn't land in the wrong one — and fires it;
- the write is **verified**: Done is reported only when Jira did not reject the transition. A
  transient failure is reported as no-change so the retry path re-attempts, rather than being
  recorded as a completed transition that never happened.

The fallback path (no explicit ref) marks the item shipped: it comments `Shipped via <pr-url>` on
the issue and then transitions it to Done the same way. The comment is best-effort — a failed
comment never blocks the transition. If the issue's current status offers **no** transition into a
done-category status, the PR-link comment still lands and the state is left alone.

State requests map like this:

| requested state | Jira status category | preferred status name |
|---|---|---|
| `done`, `complete`, `completed`, `shipped`, `merged`, `closed`, `resolved` | `done` | **Done** |
| `in-progress`, `started`, `doing`, `wip`, `active` | `indeterminate` | **In Progress** |
| `cancel`, `canceled`, `cancelled`, `wontfix`, `declined`, `dropped`, `obsolete` | `done` | **Cancelled** |
| anything else | *(unmapped)* — skipped loudly, **nothing filed** | |

The preferred name only breaks ties *within* the mapped category; if your workflow's canonical
statuses are named differently, the first transition into that category wins.

### 2.7 Sweeps read state back

Background reconciliation reads each tracked item's live `statusCategory` (`done` → closed,
`indeterminate` → in-progress, everything else → open) plus its last-updated day, which is the
evidence a claim guard cites when it refuses a stale pick. A ref that resolves to **no** issue
reads as *unknown* — not as "open" — so the sweep's failure backoff takes over instead of looping
forever on a heal that can never succeed.

### 2.8 Amending and hand-driven state changes

- A clarification is posted as a comment on the existing issue, leaving status and summary
  untouched.
- A "mark ENG-12 done" style request **transitions the existing issue** instead of filing a new
  one.
- Both resolve conservatively: by key (`ENG-12`, a leading `#` is tolerated), or — when the request
  names no key — by a JQL `summary ~` search that must match **exactly one** issue. Zero or
  ambiguous matches change nothing and say why on stderr; the adapter skips rather than guesses.

Every state write is journaled with its component attribution, so `herd log` answers "which
component moved `ENG-12` to `done`, on which PR" in one line.

---

## Limits and caveats

Known and honest, as of this adapter:

**Platform**

- **Jira Cloud only.** The endpoints are REST v3 (`/rest/api/3/…`, `/search/jql`); Jira Server /
  Data Center is not supported.
- **Basic auth with an API token.** No OAuth, no PAT-style bearer flow. The claimant identity is
  the token's own account, so a shared token makes every seat look like the same operator to
  Jira's assignee field.
- `curl` and `python3` are hard requirements; a missing `curl` is a loud exit, not a soft skip.

**Issue creation**

- Only `project`, `summary`, `description`, and `issuetype` are set. A project whose create screen
  **requires** other fields (a custom mandatory field, a required component, a required priority)
  will reject the create — it is reported as no-change and, with `CREATE_SELFHEAL` on, retried from
  the queue; it does not repair itself by learning the required fields.
- `JIRA_ISSUE_TYPE` (default `Task`) must exist in the target project.
- No epic/parent link, labels, priority, components, sprint, or story points are set — the adapter
  files a bare issue.
- The description is written as a **single plain-text ADF paragraph**: markdown in the request text
  is stored verbatim, not rendered as Jira rich text.

**Reading**

- The open list is capped at **250** issues per query and does **not** paginate — a project with
  more open issues than that is silently truncated at the cap.
- `herd backlog show` needs a real `PROJ-NUMBER` key; a title fragment is not accepted there.
- Reading rich text back flattens ADF to plain text (tables, panels, and links lose their
  structure).

**Optional ops this adapter does not implement** — each degrades soft, none is an error:

| missing op | visible effect |
|---|---|
| closed-item listing | `herd backlog --closed` prints `backend 'jira' defines no _backend_list_closed op — nothing to show.` — so a "does this already exist?" search can't see already-closed duplicates |
| claim release | `CLAIM_RELEASE=release` degrades to `flag`: a dead builder's wedged issue is journaled and surfaced, but the assignee is **not** cleared — a human unassigns it |
| tracker inbox comments | `OPERATOR_INBOX`'s tracker feed is empty on Jira (the PR-comment feed still works), so cross-seat notes left as Jira comments are not surfaced automatically |
| missing-item probe | `herd sweep`'s retroactive-relink leg is inert: a merged PR whose `Refs:` points at an issue that was never created is not detected |
| plan-time assignee | `herd backlog queue` posts the 📌 comment only; unlike the Linear/GitHub backends it does not also set the plan-time assignee, so the intent is visible via `herd backlog queued` rather than in every Jira client view |

**Multi-operator**

- Jira has no compare-and-swap. The claim is read → write → re-read, which **narrows** the race to
  a couple of round-trips; it does not eliminate it. Two seats claiming the same issue within that
  window can both believe they won.
- Cross-repo filing with `herd report --to <link>` wires a link's `tracker_target` only for the
  Linear backend. A **Jira** peer link's target is not applied, so such a report routes to whatever
  `JIRA_PROJECT_KEY` your own secrets set. `herd link --scan` flags a blank Jira target for exactly
  this reason — treat cross-repo filing into a Jira peer as unsupported for now.

**Workflow shape**

- A state change is a workflow **transition**, so the target must be reachable from the issue's
  *current* status. An issue parked in a status with no path to a done-category status cannot be
  closed by the fleet; the attempt says so and files nothing.
- Statuses are matched by category first, name second. A workflow with several done-category
  statuses lands on one named *Done*/*Cancelled* when present, and otherwise on whichever the API
  returns first.

---

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `Jira API round-trip FAILED (bad creds or network) — nothing was changed` | the switch's `/myself` preflight rejected the credentials. Re-check the base URL (scheme + host, no trailing path), the account email, and that the token belongs to that account. Nothing was written |
| `jira backend: … not set — add to .herd/secrets` | one of the three required values is missing from `.herd/secrets`, or the secrets file isn't being sourced (it must sit at `<repo>/.herd/secrets`) |
| Issues from another project appear in `herd backlog` | `JIRA_PROJECT_KEY` is unset, so the open list spans every project the token can see. Set it in `.herd/secrets` |
| Every new issue lands in the wrong project | same cause — with no project key, creates go to the first project the token can see |
| A merged PR left its issue open | either the `Refs:` line was missing/malformed, or the issue's current status offers no transition into a done-category status. `herd log` shows the attempted tracker write and its result |
| The backlog pane still shows the old backend | the viewer binds the backend at process start — run `herd pane backlog` (and close a stale viewer process if it persists) |

---

## Future work — there is no Jira-side UI

Everything above is driven from your terminal. The adapter reads and writes Jira issues; it does
**not** put anything in Jira's own interface beyond the issue fields, comments, assignee and status
it sets. A Jira user watching the board sees the fleet's effects (the issue moves to *In Progress*,
a PR link comment appears, it lands in *Done*) but has no in-Jira view of agent status or gate
verdicts, and no way to hand work to the fleet from a Jira screen.

A "Herd Console for Jira" Forge panel — per-issue fleet state (agent → PR → gate verdicts → merged)
plus a *send to fleet* action, fed by the watcher's existing journal — is **phase 2 of the same
roadmap item** ([gh #626](https://github.com/briankeegan1/herdkit/issues/626), tracked as
HERD-662). It is deliberately gated on real adoption signal and **is not built** — treat it as a
direction, not a shipping date.

---

## See also

- [`docs/codemap.md`](codemap.md) — where the adapter sits in the engine tree
  (`scripts/herd/backends/jira.sh`) and who sources it.
- [`docs/capabilities-overview.md`](capabilities-overview.md) — every `herd` command and config key,
  including `SCRIBE_BACKEND` and the claim/queue governance keys referenced above.
- [`docs/multi-seat-doctrine.md`](multi-seat-doctrine.md) — the invariants behind claiming and
  planned-work markers when several operators share one tracker.
