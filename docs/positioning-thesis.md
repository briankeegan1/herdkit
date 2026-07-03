# Positioning thesis — herdkit vs the raw Claude harness

> Deliverable for the **EPIC** in `BACKLOG.md`: _herdkit vs the raw Claude harness — falsify the
> null hypothesis that herdkit adds nothing a Workflow script can't already do._ This is the
> written argument (sequencing step 1); the falsification benchmark (step 3) is a separate item.
> The claim here is deliberately narrow and falsifiable — it names the one axis on which herdkit
> is not reducible to a Workflow script, concedes every axis on which it is, and states the
> condition under which the whole project should be downgraded. Citations are `file:line` into
> `scripts/herd/` unless noted.

---

## 1. The null hypothesis, stated fairly

The raw Claude harness already ships the primitives people reach herdkit for. The **Workflow**
tool expresses fan-out (`parallel`/`pipeline`), loop-until-dry discovery, worktree isolation
(`isolation: 'worktree'`), and adversarial multi-agent review — the exact shapes herdkit wires
together. Hooks enforce gates. Subagents give parallelism. So the honest null hypothesis is:

> **herdkit is just an opinionated Workflow script.** Anything its watcher, reviewer, and merge
> gate do, a sufficiently careful Workflow author could inline — and pay fewer tokens, incur less
> latency, and carry less orchestration surface doing it.

We should not try to win by running a within-session task battery. herdkit would **lose** that
benchmark — more processes, more moving parts, more failure modes — and running it to declare
victory would rig the result. If the null hypothesis falls, it must fall to a workload the raw
harness **architecturally cannot complete**, not to a stopwatch we tilted.

## 2. The one falsifying workload

There is exactly one, and it is a property of construction, not of effort:

**The harness's execution and state are conversation-scoped.** A Workflow runs to completion and
returns; its subagents die with their parent; its orchestration memory _is_ the conversation
context, so context exhaustion ends the run. Nothing about a single invocation survives the
invocation.

The falsifying scenario is therefore:

> **Drain a ~20-item backlog, unattended, overnight — surviving at least two usage-limit resets
> and a machine/terminal restart, with a hand-off to a second operator mid-run.**

A single Workflow invocation cannot do this. The moment the session ends — laptop closed, limit
hit, process killed, operator swapped — the run's execution and its entire memory of what was done
go with it. There is no resume, because there is nothing durable to resume _from_.

herdkit completes it because it externalizes **both** halves:

- **Execution → detached OS processes and herdr panes.** The watcher runs in its own pane and
  loop, discovering active worktrees and auto-merging PRs that pass the gate, independent of any
  chat session (`herd-watch.sh:1`, `agent-watch.sh`). Close the laptop; the process keeps going.
- **State → git and files, not context.** Progress lives in branches + PRs, the backlog file
  (`BACKLOG.md`), the append-only journal (`journal.sh:1` — JSONL forensic record of every
  dispatch, verdict, healthcheck attempt, merge, reap), and sha-keyed result files. A second
  operator on a different machine reads the same branches, the same `BACKLOG.md`, and runs
  `herd why <pr>` against the same journal. The run's memory is on disk, not in a context window.

That is the irreducible axis: **time + presence decoupling.** Work survives session end, context
exhaustion, restart, multi-day spans, and operator hand-off — because neither the execution nor
the memory of it was ever tied to a conversation.

## 3. Where herdkit wins vs where the harness already suffices

Be honest about both columns.

**The harness already suffices — and wins — within a session:**

- One bounded, attended task you will watch to completion. Fewer tokens, lower latency, less to
  break. A Workflow's `parallel`/`pipeline` fan-out is the right tool.
- Any orchestration whose entire lifetime fits inside one context window. herdkit's detached
  processes and on-disk state are pure overhead here — you are paying for durability you will
  never use.

**herdkit wins only when work must outlive the operator's attention:**

- Unattended drains that cross usage-limit resets, restarts, or days.
- Multi-operator hand-off, where the next person needs the run's state without the previous
  person's context.
- Post-hoc forensics on a gate decision after the session that made it is long gone
  (`herd why <pr>` over the journal, keyed by PR **and** head sha so each sha is judged once —
  `agent-watch.sh:93`).

If your work fits in the first column, use the raw harness. herdkit's value is _entirely_ in the
second column, and claiming more than that is dishonest.

## 4. Honest-disposition clause

This thesis is falsifiable and we commit to the verdict in advance. If herdkit **cannot** win on
the time/presence axis — because the harness acquires durable, detached execution primitives of
its own, or because unattended overnight backlog drain turns out not to be a real use case — then
the correct conclusion is:

> **Downgrade herdkit to "an opinionated Workflow template."** A curated set of gate shapes and
> defaults worth copying, not a capability moat.

We do not get to declare victory because a within-session run was "close." Either the decoupling
axis holds and herdkit is architecturally distinct, or it does not and herdkit is a template. The
study must be willing to write the second sentence.

## 5. The weaker secondary benefit — convention, not moat

herdkit routes every AI-authored change through GitHub's **own** durable gates: each automated
commit lands on a branch and merges through a PR that clears branch-protection + required checks —
the same auditable path a human's change would take. The healthcheck must pass and a review verdict
must be recorded before the watcher merges; verdicts are cached per PR+sha so a new commit forces a
fresh review (`agent-watch.sh:95`), and human-verify holds block auto-merge until a person runs
`herd-approve.sh` (`agent-watch.sh:56`).

This is genuinely useful — every automated change is auditable and gated instead of pushed
straight to a branch. But it is **convention and packaging, not a capability the harness lacks.**
A disciplined Workflow author could post the same PRs and wire the same checks. This benefit
erodes as the Workflow tool matures, and we should not lean on it. It rides along; it does not
carry the argument.

## 6. The litmus test

One sentence to decide which tool a given piece of work wants:

> **If you can finish it before you close your laptop → raw harness. If the work must outlive your
> attention → herdkit.**

Everything above is a defense of that line. The raw harness owns the attended, within-session
case on tokens and latency. herdkit owns exactly one thing the harness cannot express — work that
must survive the end of the session that started it — and it earns that by moving execution to
detached processes (`herd-watch.sh:1`) and state to git, the backlog file, and the journal
(`journal.sh:1`). If that axis ever stops holding, this document's own conclusion is to call
herdkit a template and move on.
