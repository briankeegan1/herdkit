#!/usr/bin/env bash
# healthcheck.java.sh (EXAMPLE) — a per-project health command for a Java project (Maven or Gradle).
# `herd init` seeds this into .herd/healthcheck.project.sh when scout detects lang=java; you can also
# copy it by hand and point HEALTHCHECK_CMD at it. Same contract as templates/healthcheck.project.sh:
# exit 0 clean, 1 code error, 2 data/env (tolerated).
set -u
DIR="${1:?usage: healthcheck.java.sh <worktree-dir> [--oneline]}"
ONELINE=""; [ "${2:-}" = "--oneline" ] && ONELINE=1
cd "$DIR" 2>/dev/null || { echo "no such dir: $DIR"; exit 1; }

# Pick the build tool present in the repo. Adapt the commands to your toolchain if needed.
if [ -f pom.xml ]; then
  COMPILE="mvn -q -e -DskipTests compile"; TEST="mvn -q -e test"
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  GRADLE="gradle"; [ -x ./gradlew ] && GRADLE="./gradlew"
  COMPILE="$GRADLE -q compileJava"; TEST="$GRADLE -q test"
else
  [ -n "$ONELINE" ] && echo "no pom.xml / build.gradle found" || echo "NO BUILD FILE (pom.xml / build.gradle)"
  exit 1
fi

# 1. Compile as the hard code gate.
if ! out="$($COMPILE 2>&1)"; then
  [ -n "$ONELINE" ] && echo "compile: $(printf '%s' "$out" | tail -1)" || { echo "COMPILE FAILED"; printf '%s\n' "$out"; }
  exit 1
fi

# 2. Test suite; classify infra failures as data/env (tolerated), everything else as a code error.
out="$($TEST 2>&1)"; rc=$?
last="$(printf '%s' "$out" | tail -1)"
if [ "$rc" -eq 0 ]; then
  [ -n "$ONELINE" ] && echo "clean — $last" || { echo "CLEAN"; printf '%s\n' "$out"; }
  exit 0
fi
if printf '%s' "$out" | grep -qiE 'connection refused|timeout|unknownhost|network|could not resolve|auth|credential'; then
  [ -n "$ONELINE" ] && echo "data/env — $last" || { echo "DATA/ENV ISSUE"; printf '%s\n' "$out"; }
  exit 2
fi
[ -n "$ONELINE" ] && echo "code error — $last" || { echo "CODE ERROR"; printf '%s\n' "$out"; }
exit 1
