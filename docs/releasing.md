# Releasing herdkit

herdkit ships three ways. This runbook covers cutting a version and publishing to each channel.
Steps that need an **operator account or credential we don't have in CI** are marked
**⚠️ HUMAN-VERIFY** — they can't be automated in the PR pipeline and must be run by the maintainer.

Distribution channels:

| Channel | Users run | Source of truth |
| --- | --- | --- |
| **curl \| bash** | `curl -fsSL …/install.sh \| bash` | [`install.sh`](../install.sh) — already live |
| **Homebrew** | `brew install briankeegan1/herdkit/herdkit` | [`packaging/homebrew/herdkit.rb`](../packaging/homebrew/herdkit.rb) |
| **npm** | `npm install -g herdkit` | [`packaging/npm/`](../packaging/npm/) |

## Versioning

One version string drives every channel. Keep these in lockstep when you bump:

- `packaging/npm/package.json` → `version`
- `packaging/homebrew/herdkit.rb` → `version` + `url` + `sha256`
- `plugin/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` → `version`

The engine's internal `HERDKIT_CONTRACT_VERSION` (in `bin/herd`) is a **separate** compatibility
contract number — bump it only on an engine-contract change, not on every release.

---

## 1. Cut the release (Git tag + GitHub release)

```bash
VER=0.1.0
# bump the version fields listed above in a normal PR, merge it, then from main:
git tag "v$VER"
git push origin "v$VER"
gh release create "v$VER" --generate-notes    # ⚠️ HUMAN-VERIFY: needs push + gh auth to this repo
```

The GitHub release auto-creates the source tarball at
`https://github.com/briankeegan1/herdkit/archive/refs/tags/v$VER.tar.gz` — Homebrew consumes it.

---

## 2. Homebrew

The formula lives in a **tap repo** `briankeegan1/homebrew-herdkit` (a separate GitHub repo whose
name must start with `homebrew-`). First release only: create that repo and add
[`packaging/homebrew/herdkit.rb`](../packaging/homebrew/herdkit.rb) as `Formula/herdkit.rb`.

Each release:

```bash
VER=0.1.0
# 1. compute the tarball checksum:
curl -fsSL "https://github.com/briankeegan1/herdkit/archive/refs/tags/v$VER.tar.gz" -o herdkit.tgz
shasum -a 256 herdkit.tgz        # copy the hash

# 2. in the tap repo's Formula/herdkit.rb, set `version`, `url` (v$VER), and paste the `sha256`.
# 3. commit + push to the tap repo.       ⚠️ HUMAN-VERIFY: needs write access to the tap repo.

# 4. verify:
brew install --build-from-source briankeegan1/herdkit/herdkit
herd doctor
```

The formula's `sha256` ships as a zero placeholder in this repo on purpose — it can only be filled
once the tarball exists (step 1).

---

## 3. npm

```bash
cd packaging/npm
npm publish --access public       # ⚠️ HUMAN-VERIFY: needs an npm account + `npm login` as the
                                  #    `herdkit` package owner (or scope it @briankeegan1/herdkit).
```

Post-publish smoke:

```bash
npm install -g herdkit
herd doctor
npm uninstall -g herdkit && rm -rf ~/.herdkit
```

The npm `postinstall` pins the engine checkout to the `v<version>` tag, so **publish npm only after
the git tag exists** (step 1).

---

## Release checklist

- [ ] Version fields bumped in npm / homebrew / plugin / marketplace and merged
- [ ] `git tag v$VER` pushed
- [ ] ⚠️ GitHub release created (`gh release create`)
- [ ] ⚠️ Homebrew tap formula updated with real `url` + `sha256`, `brew install` verified
- [ ] ⚠️ `npm publish` done, `npm i -g herdkit` verified
- [ ] `herd doctor` green from each channel install
- [ ] CI green on `main` (ubuntu + macOS required; Windows documented-partial — docs/windows.md)
