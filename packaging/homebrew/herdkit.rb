# herdkit.rb — Homebrew formula for herdkit.
#
# SKELETON: publish this into a tap repo `briankeegan1/homebrew-herdkit` (docs/releasing.md).
# Then:  brew install briankeegan1/herdkit/herdkit
#
# herdkit is a bash engine with no compile step: the formula vendors the checkout into libexec
# and symlinks the `herd` CLI into the Homebrew prefix. Two placeholders MUST be filled at release
# time (they need a cut release tarball — HUMAN-VERIFY in docs/releasing.md):
#   • `url`     — the GitHub release tarball for the version
#   • `sha256`  — its checksum (`brew fetch` / `shasum -a 256` prints it)
class Herdkit < Formula
  desc "Config-driven multi-agent coordinator workflow for Claude Code, built on herdr"
  homepage "https://github.com/briankeegan1/herdkit"
  # Bump `version` + `url` + `sha256` together each release (docs/releasing.md).
  version "0.1.0"
  url "https://github.com/briankeegan1/herdkit/archive/refs/tags/v0.1.0.tar.gz"
  # REPLACE at release time: shasum -a 256 of the tarball above.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/briankeegan1/herdkit.git", branch: "main"

  # Runtime deps. bash + git are load-bearing; python3 backs status/backlog rendering.
  # `herdr` (the terminal multiplexer) is an OPTIONAL view — the headless driver runs without it.
  depends_on "bash"
  depends_on "git"
  depends_on "python@3.12"

  def install
    # No build step: vendor the engine into libexec, expose `herd` on PATH.
    libexec.install Dir["*"]
    (bin/"herd").write <<~SH
      #!/usr/bin/env bash
      exec bash "#{libexec}/bin/herd" "$@"
    SH
    chmod 0755, bin/"herd"
  end

  def caveats
    <<~EOS
      herdkit needs a few external tools it does not vendor:
        • claude  (Claude Code CLI)          — the agent runtime
        • gh      (GitHub CLI, authenticated) — PR/merge operations
        • herdr   (optional)                  — the herd control-room view; the headless
                                                driver runs fully without it
      Verify your setup with:  herd doctor
    EOS
  end

  test do
    # Smoke: the CLI runs and reports a version without a configured project.
    assert_match(/herd/i, shell_output("#{bin}/herd --help 2>&1", 0))
  end
end
