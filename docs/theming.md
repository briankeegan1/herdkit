# Theming herd surfaces (`HERD_THEME`)

Every color-emitting herd surface — the `herd watch` console, the backlog and task-spec viewers, and
the `herd` CLI (`status` / `fleet` / `cost` / `why`, plus `herd-approve.sh list`) — is themed by a
single config key:

```sh
HERD_THEME="tokyonight"   # .herd/config — default; the shipped built-in
```

The default, `tokyonight`, renders **byte-identically** to the palettes herd hardcoded before theming
existed, so an existing project sees no change.

## What a theme is

A theme is a **directory** holding two files:

| file         | consumed by                                   | what it is                                                                 |
|--------------|-----------------------------------------------|----------------------------------------------------------------------------|
| `palette.sh` | the status consoles + the CLI                 | shell `KEY=value` assignments for the color variables (sourced, not run)   |
| `glow.json`  | the glow-rendered markdown viewers            | a [glamour](https://github.com/charmbracelet/glow) style JSON              |

`palette.sh` defines two groups:

- **`C_*`** — the truecolor console palette (`C_RESET C_BOLD C_BLUE C_CYAN C_GREEN C_YELLOW C_RED
  C_DIM`), used by the `herd watch` status console (a live pane, so 24-bit truecolor).
- **`C_CLI_*`** *(optional)* — a 16-color palette (`C_CLI_BOLD C_CLI_DIM C_CLI_GREEN C_CLI_YELLOW
  C_CLI_RED C_CLI_RESET`) for the plain CLI surfaces, which stay readable on basic terminals. If a
  theme omits these, the CLI falls back to the theme's `C_*` truecolor values — so a theme that sets
  only `C_*` still recolors the CLI.

## Resolution order

For each file, herd looks in order and uses the first hit:

1. `.herd/themes/<name>/<file>` — **your** theme, project-local
2. `templates/themes/<name>/<file>` — an engine **built-in**
3. `templates/themes/tokyonight/<file>` — the **fallback** (always present)

Resolution is **per file**, so a theme may supply only `palette.sh` or only `glow.json` and the other
falls back to the tokyonight default.

## Fail-soft guarantees

- An **unknown or incomplete** theme (its directory missing, or missing one of the two files) warns
  **loudly, once** to stderr and falls back to tokyonight — it never breaks a console.
- A **missing theme file** resolves to the built-in default.
- **`NO_COLOR`** set (any value), or a **non-TTY** stdout, renders every surface **plain**.
- A hostile/typo'd `HERD_THEME` (e.g. containing `/` or `..`) is sanitized to `tokyonight`, so it can
  never traverse out of the theme directories.

## Drop in your own theme

```sh
# From your project root — copy the built-in as a starting point:
mkdir -p .herd/themes/mytheme
cp "$(herd --home 2>/dev/null || echo "$HERDKIT_HOME")"/templates/themes/tokyonight/palette.sh .herd/themes/mytheme/
cp "$(herd --home 2>/dev/null || echo "$HERDKIT_HOME")"/templates/themes/tokyonight/glow.json  .herd/themes/mytheme/
# …edit the C_* values in palette.sh and the colors in glow.json, then:
#   HERD_THEME="mytheme"   in .herd/config
```

A minimal `palette.sh` (only what you want to recolor; everything else keeps the tokyonight default):

```sh
# .herd/themes/mytheme/palette.sh
C_GREEN=$'\033[38;2;120;220;120m'   # console "landed" green
C_RED=$'\033[38;2;240;90;90m'       # console "needs you" red
# C_CLI_* omitted → the CLI reuses the C_* values above
```

Changes take effect the next time each surface launches — restart the watcher (`herd reload`, or
`herd pane watch` / `herd pane backlog`) to pick up a new console/viewer theme immediately.

## For engine authors

The resolver is `scripts/herd/theme.sh`. A new color surface sources it (after `herd-config.sh`
where possible) and calls one of:

- `herd_theme_load_console` — sets the truecolor `C_*` console palette.
- `herd_theme_load_cli` — sets the 16-color `c_*` CLI palette (prefers `C_CLI_*`, falls back to `C_*`).
- `herd_theme_glow_style` — echoes the resolved `glow.json` path for `glow -s "$STYLE"`.

All three honor the resolution order, the warn-once fallback, and `NO_COLOR` / non-TTY plain mode.
