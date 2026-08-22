# Switching the agent runtime

Use the explicit switch command to move one machine between Claude Code, Codex, and Grok without
changing the project's shared configuration:

```sh
herd runtime switch codex --dry-run
herd runtime switch codex
herd runtime switch grok              # or switch to Grok
```

The command shows every proposed value first: `HERD_DRIVER`, all `MODEL_*` runtime roles, and all
`REVIEW_MODEL_*` tiers. Before it writes anything, it verifies that the target binary is installed
and logged in and that the driver can compose both interactive and one-shot argument vectors. A
failed check and `--dry-run` leave `.herd/config.local` byte-identical.

On success, the complete map is published to the gitignored `.herd/config.local` with one atomic
rename, then the control room is reloaded exactly once. The committed `.herd/config` and
`.herd/secrets` are never changed. The last output line gives the reverse command; for example:

```sh
herd runtime switch herdr-claude
```

If preflight reports that the runtime is logged out, authenticate directly and retry:

```sh
claude auth login    # Claude Code
codex login          # Codex
grok auth login      # Grok
```

Model suggestions are a complete role preset, not a migration of credentials or shared policy.
Review the dry-run when your account uses a different model catalog, then adjust an individual
machine-local role with `herd config set --local KEY VALUE` if needed.
