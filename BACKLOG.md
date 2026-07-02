# herdkit — backlog

> Single source of truth for planned herdkit work. The coordinator owns this file; the async
> scribe is the only automated writer. 🔜 planned · 🚧 in progress · ✅ shipped. herdkit is
> developed *using the herd* (workspace wB) — these items get built through its own lanes.

## Cross-repo orchestration (deferred — validate via a simulation FIRST, don't over-build; link registry foundation ✅ shipped PR #14)

- 🔜 **`herd upgrade` versioned migrations** — `migrations/vN→vM.sh` transform a consumer's config/hooks to a new engine contract, so breaking changes are inherited without clobbering custom setup. *(Gap 4 in `docs/gap-report-cross-repo-loop.md`.)*

## Enterprise / multi-user optionality (deferred — solo is the default today; bank the config seams now)

- 🔜 **Dispatch vs. dependency intent** — `herd report --to B` (fire-and-forget issue, default) vs `--to B --dep` / `herd depend B#id` (records `blocked-on` + watched). Reclassify/remove via `herd deps rm|demote` — a dep is editable data, never stuck. *(Gap 3 in `docs/gap-report-cross-repo-loop.md`: `.herd/deps` schema + `herd depend/deps list/rm`; depends on the link registry above for `--to <project>`.)*
- 🔜 **Watcher flexibility for long-pending deps** — backoff polling; richer dep states (`open/in-review/in-progress/stalled/closed`); surface `stalled` + optional TTL so a slow enterprise PR never silently rots. A `blocked-on` is a status line, never a workspace freeze.
- 🔜 **Configurable watcher views** — lenses `mine | all | deps | review-queue` + filters (author/assignee/label/status); default in `.herd/config`.
- 🔜 **Multi-user / team mode** — `WATCHER_SCOPE=mine|all` + ownership/assignee filter; auto-merge scoped to OWNED PRs only (never blind-merge teammates'), building on the required-checks gate (PR #5). `solo` default; `team` is a config flip.

## Workflow control & discoverability

> Build order: F1 (merge policy) first; capabilities manifest + template-sync guard as one PR; init detection + flow-preference interview as one PR; herd config last (leans on the manifest for key validation).

- 🔜 **Init-time GitHub detection** — `cmd_init` (bin/herd:104-284) makes zero `gh api` calls today; add a detection pass: branch protection on the default branch, required-review count, required checks, CODEOWNERS, allowed merge methods; show findings and derive safe defaults (required reviewers present ⇒ default `MERGE_POLICY=approve`, never `auto`); degrade gracefully without remote/gh.
- 🔜 **Flow-preference interview + draft-PR flow** — New `herd init` questions → config keys: `PR_FLOW=direct|draft` (draft: lanes instruct builders `gh pr create --draft`; watcher already holds `DRAFT`, agent-watch.sh:157), `PR_READY_WHEN=builder|coordinator|human`, `LOCAL_REVIEW=none|pre-pr` (run the review gate in the worktree BEFORE the PR is public vs today's post-PR review), `MERGE_METHOD`, `DELETE_BRANCH_ON_MERGE`; thread prefs into the lane rules text (herd-quick.sh:58-61, herd-feature.sh:50-53).
- 🔜 **`herd config` + coordinator Workflow settings mode** — `herd config list|get|set` with key validation, aware of what each change requires: watcher keys ⇒ restart watcher (pid file `.watcher-<slug>.pid`), coordinator-facing keys ⇒ re-render skill (render step at bin/herd:277-278); coordinator menu gains a 'Workflow settings' entry to view/change any workflow pref anytime and relaunch affected pieces — nothing is init-only.
- 🔜 **Review-gate visibility + human override** — today a review BLOCK is nearly invisible: the reviewer pane (herd-review.sh) is transient and vanishes after the verdict, the full block reason lives only as a PR comment, and the herd-watch row just says 'needs you · review blocked' with no pointer — so the user has no idea what blocked or how to proceed (observed on PR #28). Build: (1) reviewer runs in a persistent, labeled herdr pane like builders/scribe, kept until its verdict is acted on (re-review or merge) — AND the pane must stream live progress: today it is blank for the entire run (observed again on PR #28's re-review) because herd-review.sh:123 invokes `claude -p`, which buffers all output and writes the log only on exit, so the `tail -f` pane shows nothing and then the tab closes (herd-review.sh:128); stream instead (e.g. `--output-format stream-json --verbose` piped through a compact formatter into the log); (2) the console 'review blocked' row shows the PR # and a pointer to the reason (e.g. 'see PR comment / `herd-approve.sh why <pr#>`'); (3) a `why` subcommand on herd-approve.sh that prints the latest review verdict + block reason for a PR from the ledger/PR comments; (4) a first-class human override — `herd-approve.sh override <pr#>` — that records an overrule of a cached BLOCK so the watcher proceeds to the approval/merge path, instead of the only escape hatch being a manual `gh pr merge` outside the system; (5) console should also explain the proceed paths on a blocked row (new commit auto-re-reviews; override available).
- 🚧 **Capabilities manifest** *(worktree capabilities-manifest)* — Machine-readable registry of EVERY command, lane, lever, and config key with a one-line 'when to surface to the user'; `herd init`/`upgrade` render it into the coordinator skill via a new `{{CAPABILITIES}}` template token (templates/coordinator.md.tmpl has only 8 tokens today); coordinator on-invocation also reads live state (`.herd/links`, `.herd/deps`, `MERGE_POLICY`) so configured features surface with status; manifest doubles as the key-validation table for `herd config`.
- 🚧 **Template-sync guard** *(worktree capabilities-manifest)* — Leak-guard-style healthcheck rule: a PR adding a `cmd_*` subcommand, a `herd-config.sh` key, or a lane script without touching the capabilities manifest fails with a `CODE` error, so the capabilities manifest can never drift.
- 🚧 **Herd-watch console: show PR # on in-flight rows** *(worktree watch-pr-display)* — when an in-flight builder already has an open PR, the in-flight row should display the PR number (like recently-landed rows do), so the user can match builders to PRs at a glance; reuse the PR data the watcher already fetches.

## Reliability / safety

- 🔜 **Pre-trust fix (PR #22) is ineffective — builders still die on the folder-trust prompt** — new-feature.sh:43-49 writes an empty {} to `<worktree>/.claude/settings.json` claiming Claude Code treats any project-level settings file as a trust marker; that premise is wrong (folder trust is recorded in `~/.claude.json` keyed by project path), so freshly-spawned builders can still hit the interactive trust prompt and die/vanish with zero commits — observed with worktree watch-pr-display: agent pane died at startup leaving an empty shell pane, watcher correctly flagged 'idle · no PR'. Real fix candidates, to be verified against how Claude Code actually records trust: seed the project entry in `~/.claude.json` (e.g. `hasTrustDialogAccepted`) before launch, or have the launcher detect the trust prompt in the pane and answer it, or find a supported non-interactive trust flag. The stalled-builder detection half of PR #22 works and stays.

## Someday / Deferred

- 🔜 **Phase 4: onboard an external consumer** — `herd init` against a genuinely different repo (web server/library); the real abstraction test (§8).
- 🔜 **Claude-plugin wrapper** — ship the skill as a Claude Code plugin while the CLI stays source of truth (§4).

## Recently shipped

- ✅ **Merge policy + approval queue** — MERGE_POLICY=auto|approve|observe, MERGE_METHOD, sha-keyed approvals ledger + herd-approve.sh. *(PR #26)*
- ✅ **`_backend_item_state <id>` op + dependency-watcher** *(PR #25)*
- ✅ **Cross-repo dependency-loop SIMULATION** *(PR #24)*
- ✅ **Platform-agnostic install + shell portability** *(PR #23)*
- ✅ **Lane-spawned builders can silently stall on the folder-trust prompt** *(PR #22)*
- ✅ **Watcher singleton spawn-lock + stale reap** *(PR #21)*
- ✅ **Cross-repo link registry (`.herd/links`)** — foundation for general peer dispatch (A → any project B); each link = name + repo coordinates + backend adapter + tracker target, so `herd report --to <project>` resolves arbitrary linked projects; `tracker_target` wired as `LINEAR_TEAM_ID`. *(PR #14, follow-up e1a6877)*
- ✅ **Multi-tenancy: project-scoped singletons** — coordinator/scribe/researcher tab+agent names suffixed by `WORKSPACE_NAME`, so two projects coexist in one herdr without colliding (tab-close + spawn-locks now per-project). *(PR #11)*
- ✅ **Harden `herd report`** — backend-agnostic dispatch (`HERD_REPORT_BACKEND` → `_backend_add_item`) + dedup-before-filing. *(PR #10)*
- ✅ **Feedback loop — `herd backlog`** drains the active backend (file/github/linear) as the work source + `herd.sh` launcher. Cross-repo dispatch loop proven end-to-end. *(PR #7, #9)*
