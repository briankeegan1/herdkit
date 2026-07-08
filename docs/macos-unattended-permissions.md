# Running unattended on macOS — the TCC permissions posture

> macOS gates access to protected resources behind **TCC** (Transparency, Consent & Control): the
> "*&lt;App&gt; would like to access …*" dialogs. TCC is designed for an **interactive** user who
> clicks Allow. herdkit is designed to run **unattended** — a coordinator delegating to isolated
> builders overnight. When those two meet, a hidden consent dialog can **silently pause a builder**:
> the `claude` process blocks on an OS prompt no one is there to click. This doc explains the failure
> mode, the posture that prevents it, and how to detect the symptom. It is **operational guidance**,
> not a config lever — nothing here changes engine behavior.

---

## The failure mode

A builder is a **detached `claude` process** the watcher launches into an isolated worktree (via the
runtime driver — `herdr agent start` under the default `herdr-claude` driver, a `nohup` background
process under `HERD_DRIVER=headless`). It then reads and writes files, runs your healthcheck, and
shells out to `git` / `gh`.

The moment any of that touches a **TCC-protected resource**, macOS interposes a consent dialog and
**blocks the calling operation until the dialog is answered**. Unattended, no one answers it. The
builder doesn't crash and doesn't error out cleanly — it **stalls**, mid-task, waiting on a modal
that may not even be visible (it is attributed to the *responsible* app — the terminal or launcher
that started herd — and can sit behind other windows or on another Space). One stalled builder holds
its worktree and its slot until a human notices.

The resources that commonly trip this for a coding agent:

| TCC category | What triggers it | Why a builder hits it |
|---|---|---|
| **Full Disk Access** (FDA) | Reading files under protection: `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Library/…`, other apps' data, another user's files, external volumes | A worktree or dependency cache under a protected folder; a healthcheck or build step that reads protected paths; `git`/`gh` reading credentials under `~/Library` |
| **Automation** (Apple Events) | One app scripting another via `osascript` / AppleScript | herdkit's **native notifications** call `osascript -e 'display notification …'` (best-effort, in `driver.sh`); AppleScript that *controls* another app (System Events, Terminal) additionally prompts for Automation |
| **Files & Folders** | Per-folder access to Desktop / Documents / Downloads for a non-FDA app | Same as FDA but the narrower, per-folder prompts on recent macOS |

The trap is that on a fresh machine **the first** access in each category prompts; once granted it
never prompts again. So the pipeline can run clean for a human operator during setup and then stall
the first time it runs truly unattended and hits a category that was never pre-granted.

---

## Recommended posture

The goal: **no interactive TCC prompt can ever be the thing a builder is waiting on.** Achieve it by
pre-granting what herd legitimately needs, keeping worktrees out of protected locations, and removing
the one place herd itself reaches for Apple Events.

### 1. Pre-grant Full Disk Access to the app that runs herd

TCC attributes access to the **responsible application** — the terminal emulator or launcher that is
the ancestor of the `claude` / `git` processes, **not** `claude` or `git` themselves. Grant FDA to
whatever actually launches the herd:

- **Terminal-launched** (you start the coordinator in Terminal.app / iTerm2 / your herdr host):
  *System Settings → Privacy & Security → Full Disk Access* → add and enable **that terminal app**.
- **launchd / SSH / headless** (a `LaunchAgent`/`LaunchDaemon`, or a login shell over SSH): grant FDA
  to the binary that the job execs — typically `/bin/bash`, or the shell/agent binary named in the
  plist's `ProgramArguments`. A LaunchAgent runs in the user's GUI session and can raise a prompt no
  one sees; a LaunchDaemon runs with no session and will simply **fail or hang** the protected access.

After granting FDA, **fully quit and relaunch** the app — TCC grants apply to newly launched
processes, not already-running ones.

### 2. Keep worktrees and caches out of protected folders

`WORKTREES_DIR` is a sibling of `PROJECT_ROOT`, so the cleanest fix is to keep the **whole project
outside** the protected set. Do **not** place `PROJECT_ROOT` / `WORKTREES_DIR` (or build/dependency
caches) under `~/Desktop`, `~/Documents`, or `~/Downloads`. A path like `~/src/<project>` or
`~/herd/<project>` never enters TCC's Files-&-Folders surface, so those prompts can't fire at all —
this is the belt-and-suspenders complement to granting FDA.

### 3. Run headless so no cockpit UI is the thing prompting

`HERD_DRIVER=headless` runs the whole pipeline with **no herdr panes** — builders detach as
background `nohup claude` processes and every load-bearing path (merge gating, journal, limit
detection, notifications) runs paneless (see
[`docs/driver-abstraction.md`](driver-abstraction.md)). This removes the interactive terminal
cockpit from the unattended path; you still must grant FDA to whatever `launchd`/shell context execs
the engine (step 1), because that context is now the responsible app.

### 4. Remove the one Apple-Events reach: native notifications

herdkit's notifications are always written to a durable `.herd/notifications.log` sink; the **native**
desktop toast is an *additional* best-effort call to `osascript` (`driver.sh`). `display notification`
does not itself require Automation, but it is the one spot where herd invokes AppleScript, and stricter
policies (or MDM) can gate `osascript` behind an Automation prompt. On an unattended box, set
**`HERD_HEADLESS_NATIVE_NOTIFY=off`** to skip the native toast entirely and rely on the durable log
(plus `notify-send` on Linux, which is unaffected). If you keep native toasts, pre-approve the
terminal/launcher under *Privacy & Security → Automation* and *→ Notifications*.

### 5. Verify the grants are real before you walk away

Do a **dry unattended run**: launch the pipeline the same way it will run overnight (same launcher,
same `HERD_DRIVER`, same working directory), let one builder go end-to-end, and confirm it opens a PR.
If it stalls, you are missing a grant — see detection below. Grants made while a process was already
running don't take effect until relaunch, so always re-verify **after** the relaunch.

---

## Detecting the symptom

A TCC-blocked builder looks like a **silent stall**, not an error. Distinguish it from an ordinary
slow build or a usage-limit hold with these signals:

- **`herd status` / the watch console.** The watcher runs a **transcript-growth stall detector**
  (`agent-watch.sh`): a builder whose transcript stops growing between polls surfaces as a stalled
  row rather than a healthy 🔨 building one. A TCC-blocked `claude` produces **no new transcript
  output** while it waits on the dialog, so it reads exactly as a stall. A builder that was killed
  or whose process vanished with no PR shows up via **dead-builder detection** instead — a different
  row, useful for ruling TCC out.
- **Tail the agent's log.** Read the stalled builder's captured output (the `read-pane` capability —
  `bash scripts/herd/driver.sh read-pane <slug>` under headless tails the registry log). A build that
  froze partway through a file read or a step that touches a protected path, with no error line, is
  the TCC fingerprint. Contrast: a usage-limit hold logs the limit message; a real crash logs a
  stack/exit.
- **Ask macOS directly.** TCC decisions are logged by the system. Watch them live while you reproduce:
  ```sh
  log stream --style compact --predicate 'subsystem == "com.apple.TCC"'
  ```
  A `Prompting user` / `denied` line naming your terminal or launcher and a service like
  `kTCCServiceSystemPolicyAllFiles` (Full Disk Access) or `kTCCServiceAppleEvents` (Automation) is a
  direct confirmation of which grant is missing. *System Settings → Privacy & Security* is where you
  then add it.
- **`herd why <pr#>` / `herd log`** ground the *engine's* view of a PR, but a TCC stall happens
  **before** any gate event — the journal will simply show the builder dispatched and then nothing.
  That silence, combined with a stall row and a frozen log, is itself the tell.

---

## Quick checklist

- [ ] FDA granted to the **terminal/launcher** that runs herd (not to `claude`/`git`), then relaunched.
- [ ] `PROJECT_ROOT` / `WORKTREES_DIR` **not** under `~/Desktop`, `~/Documents`, or `~/Downloads`.
- [ ] Unattended context runs **headless** (`HERD_DRIVER=headless`) or in an already-permissioned terminal.
- [ ] `HERD_HEADLESS_NATIVE_NOTIFY=off` on unattended boxes (or terminal pre-approved for Automation/Notifications).
- [ ] A **dry unattended run** took one builder to a PR without stalling — verified after the final relaunch.
