# Connector seams (edges-only)

**Status:** shipped — the two edges below (**FETCH** and **POST**), their templates, and one
worked end-to-end sim (`tests/test-connector-seams.sh`, zero-network) are in the tree. This is the
**independently-shippable docs + template half** of HERD-170; it depends on nothing else.

**Origin:** HERD-170. Projects routinely need to move data *across the boundary* of a herd run —
pull a list/config/dataset in before a run, push a result/notification out after a merge. herdkit
should make that a **thin, documented edge**, not a framework. So this is deliberately *edges-only*:
**no per-service code, no in-workflow API calls, no connector catalog.** Two seams, two templates,
one example.

---

## The two edges

```
   ┌── FETCH edge ──┐        run reads          ┌── POST edge ──┐
   │ url/API ──▶ file│ ─────────────────▶ … ──▶ │ file ──▶ endpoint│
   └────────────────┘   (pre-run converter)      └────────────────┘
      templates/connector-fetch.sh                templates/connector-post.sh
      (a pre-run step you call)                    (a steps.tsv POST-MERGE step)
```

### FETCH — a pre-run converter (`templates/connector-fetch.sh`)

A small, reusable converter that pulls from a URL/API and lands the bytes in a **file**. It is the
*one* network touch: it runs **before** the run, writes a plain file, and the workflow only ever
**reads** that file. It never makes an API call from inside the workflow.

Wire it by copying the template to your project (e.g. `.herd/connector-fetch.sh`) and calling it as
the first thing your pipeline/skill/command does — or by hand before a run:

```sh
CONNECTOR_FETCH_URL="https://api.example.com/items" \
CONNECTOR_FETCH_OUT=".herd/inbox/items.json" \
  bash .herd/connector-fetch.sh
```

Optionally add a **screen** pass — a filter/projection applied to the fetched bytes before they
land (reads stdin, writes stdout):

```sh
CONNECTOR_FETCH_URL="https://api.example.com/items" \
CONNECTOR_FETCH_OUT=".herd/inbox/items.tsv" \
CONNECTOR_FETCH_SCREEN='grep -v "^#"' \
  bash .herd/connector-fetch.sh
```

Knobs (all env; see the template header for the full contract):

| var | meaning |
|-----|---------|
| `CONNECTOR_FETCH_URL` | source URL/API. **Empty ⇒ dormant no-op.** |
| `CONNECTOR_FETCH_OUT` | destination file the workflow reads. |
| `CONNECTOR_FETCH_CMD` | override the fetch mechanism (the **stub seam** — see testing). Default: `curl`, else `wget`. |
| `CONNECTOR_FETCH_SCREEN` | optional transform/filter over the fetched bytes. |
| `CONNECTOR_FETCH_STRICT` | `0` fail-soft (default) · `1` fail-hard. |

### POST — the existing `steps.tsv` post-merge seam (`templates/connector-post.sh`)

The POST edge adds **no new engine seam**. The pipeline-steps runner (HERD-132,
[`scripts/herd/steps.sh`](../scripts/herd/steps.sh)) already lets an operator plug a shell command
in at the **post-merge** seam. The POST edge is just a *documented + templated* use of it:
`templates/connector-post.sh` is a generic "take a file, POST it to an endpoint" command you wire
into `.herd/steps.tsv`.

Copy the template to `.herd/connector-post.sh`, then add one TAB-separated row to `.herd/steps.tsv`:

```
connector-post	post-merge	bash .herd/connector-post.sh	warn	none
```

* `at=post-merge` — runs in the **watcher's** merge sequence, after the merge lands.
* `on_fail=warn` — **fail-soft**: a dead endpoint journals a `warn` and continues; it never blocks
  a merge. (Use `on_fail=block` only if you truly want the post to gate the lane.)

Point it at an endpoint + payload:

```sh
CONNECTOR_POST_URL="https://hooks.example.com/notify" \
CONNECTOR_POST_PAYLOAD=".herd/inbox/items.tsv" \
  bash .herd/connector-post.sh
```

Knobs:

| var | meaning |
|-----|---------|
| `CONNECTOR_POST_URL` | destination endpoint. **Empty ⇒ dormant no-op.** |
| `CONNECTOR_POST_PAYLOAD` | optional file to POST as the body. |
| `CONNECTOR_POST_CMD` | override the POST mechanism (the **stub seam**). Default: `curl -X POST`. |
| `CONNECTOR_POST_STRICT` | `0` fail-soft (default) · `1` fail-hard. |

---

## Conventions (every connector edge follows these)

* **Default-off / ship-dormant.** With no URL configured (and, for POST, no `steps.tsv` row), an
  edge does **nothing**, touches nothing, and exits `0`. Dropping a template into a project is
  **byte-identical** to not having it until an operator opts in. This is what "ship-dormant" means:
  the code can land now and stay inert until wanted.
* **Fail-soft.** A fetch/screen/post error never wedges a run or blocks a merge. By default an edge
  warns, preserves any prior output (FETCH keeps a stale file rather than clobbering it), and exits
  `0`. Set the edge's `*_STRICT=1` to make errors hard when you want the edge to be a gate.
* **Byte-identical when unused.** The FETCH converter writes only its `OUT` file and only on
  success (atomically, via a temp file). The POST edge runs only when its `steps.tsv` row exists —
  and `steps.sh` is already contractually byte-identical for an absent/empty step list.

---

## The stub seam (how the worked example runs with zero network)

Both templates expose an **override command** — `CONNECTOR_FETCH_CMD` / `CONNECTOR_POST_CMD` — that
replaces the real network call. Tests (and air-gapped runs) point these at local commands, so the
whole fetch → screen → post flow exercises **without touching the network**:

```sh
# FETCH from a local fixture instead of the network:
CONNECTOR_FETCH_CMD='cat fixtures/api.json'
# POST to a local sink file instead of an endpoint:
CONNECTOR_POST_CMD='cat "$CONNECTOR_PAYLOAD" >> /tmp/sink.log'
```

The worked example — **fetch → screen → post**, driving the real templates and the real
`scripts/herd/steps.sh` post-merge seam with a **stubbed endpoint (zero network)** — lives in
[`tests/test-connector-seams.sh`](../tests/test-connector-seams.sh) and runs in the healthcheck
suite (registered in `tests/herd.bats`).

## What this is *not*

Per HERD-170, the edges intentionally stop here: **no per-service connectors** (no Linear/GitHub/…
specific code), **no in-workflow API calls** (the workflow reads a file; it never calls out), and
**no catalog** of connectors. If you need a specific service, you write the small `*_CMD` that
speaks to it — the edge stays generic.
