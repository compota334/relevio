#!/usr/bin/env bash
# relevio: regression guards for install.sh, uninstall.sh and session-start.sh.
#
# Two properties matter most here, and both are promises relevio makes out loud:
#
#   1. CLAUDE.md belongs to the user. A normal install must not create it, and
#      must not modify one that exists. The single exception is the one-time
#      MIGRATION away from v0.17, where the old marker block is CUT from
#      CLAUDE.md; everything the user wrote around it has to survive that cut
#      byte for byte.
#   2. Idempotency: running the installer again must leave an empty git diff.
#      This exists because CLAUDE.md once drifted by one blank line on EVERY
#      re-run, so `--update` always reported a change even when nothing had
#      changed. A diff that is always dirty is a diff people stop reading,
#      which is corrosive for a tool whose whole promise is that you can trust
#      what it does and does not touch.
#
# Usage:  bash tests/install.sh
# Exit 0 = all cases pass. Exit 1 = a regression.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO/install.sh"
UNINSTALLER="$REPO/uninstall.sh"
FAILURES=0

pass() { echo "  PASS  $1"; }
failed() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
check() { [ "$2" = "$3" ] && pass "$1" || failed "$1 (expected '$3', got '$2')"; }
yesno() { [ "$1" -eq 0 ] && echo yes || echo no; }

# A throwaway git repo with the given CLAUDE.md content (empty = no CLAUDE.md).
fixture() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q .
  git -C "$dir" config user.email test@relevio.local
  git -C "$dir" config user.name relevio-test
  git -C "$dir" config commit.gpgsign false
  [ -n "${1:-}" ] && printf '%s' "$1" > "$dir/CLAUDE.md"
  echo "$dir"
}

# Is the working tree clean for the given path?
diff_is_empty() { [ -z "$(git -C "$1" diff -- "$2")" ] && echo empty || echo dirty; }

# A pre-v0.18 CLAUDE.md: the user's text with relevio's old marker block in the
# middle. Reproduced here rather than fetched from git history, so the
# migration keeps being tested even once that history is far behind.
legacy_claude_md() {
  cat <<'EOF'
# Instructions for agents

- Rule above.

<!-- relevio:start -->
# Working methodology (relevio v0.17.0)

Old rules that must not survive the migration.
<!-- relevio:end -->

## Rules below
- Never deploy on a Friday.
EOF
}

echo "relevio install guards"

# --- Case 1: a clean install must not touch CLAUDE.md at all ----------------
# The headline promise of v0.18. If this ever fails, relevio is writing into a
# file it declared it would never write into.
d="$(fixture '# My project

- A rule of my own.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
check "clean install: CLAUDE.md untouched" "$(diff_is_empty "$d" CLAUDE.md)" "empty"
check "clean install: relevio.md created" "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "yes"
check "clean install: no markers written into CLAUDE.md" \
  "$(grep -c 'relevio:start' "$d/CLAUDE.md")" "0"
check "clean install: SessionStart hook registered" \
  "$(jq -r '[.hooks.SessionStart[].hooks[].command] | map(select(contains("session-start.sh"))) | length' "$d/.claude/settings.json")" "1"
check "clean install: PostToolUse hook registered" \
  "$(jq -r '[.hooks.PostToolUse[].hooks[].command] | map(select(contains("context-warn.sh"))) | length' "$d/.claude/settings.json")" "1"
rm -rf "$d"

# --- Case 2: a project with NO CLAUDE.md must not get one -------------------
d="$(fixture '')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
check "no CLAUDE.md before: none after either" \
  "$(yesno "$([ -f "$d/CLAUDE.md" ]; echo $?)")" "no"
rm -rf "$d"

# --- Case 3: repeated --update leaves a clean diff --------------------------
d="$(fixture '# My project

- A rule of my own.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm installed
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "second --update leaves no diff" "$(diff_is_empty "$d" .)" "empty"
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "further --update runs leave no diff" "$(diff_is_empty "$d" .)" "empty"
check "the user's own rule survived" \
  "$(grep -c 'A rule of my own' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 4: migration from v0.17 keeps the user's text on both sides -------
d="$(fixture "$(legacy_claude_md)")"
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm legacy
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "migration: old block gone" "$(grep -c 'relevio:start' "$d/CLAUDE.md")" "0"
check "migration: old rules gone" \
  "$(grep -c 'must not survive' "$d/CLAUDE.md")" "0"
check "migration: text above survived" "$(grep -c 'Rule above' "$d/CLAUDE.md")" "1"
check "migration: text below survived" \
  "$(grep -c 'Never deploy on a Friday' "$d/CLAUDE.md")" "1"
check "migration: relevio.md now carries the methodology" \
  "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "yes"
# The cut runs once; from then on there are no markers, so nothing can drift.
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm migrated
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "migration: re-update leaves no diff" "$(diff_is_empty "$d" .)" "empty"
rm -rf "$d"

# --- Case 5: a CLAUDE.md that held nothing but relevio's block --------------
# That file was created by relevio itself. Left behind it would be an
# "Instructions for agents" heading with no instructions under it.
d="$(fixture '# Instructions for agents

<!-- relevio:start -->
# Working methodology (relevio v0.17.0)
Old rules.
<!-- relevio:end -->
')"
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "migration: relevio-only CLAUDE.md removed" \
  "$(yesno "$([ -f "$d/CLAUDE.md" ]; echo $?)")" "no"
rm -rf "$d"

# --- Case 6: malformed legacy markers must abort, not eat the user's text ---
d="$(fixture "$(legacy_claude_md | grep -vF '<!-- relevio:end -->')")"
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm broken-markers
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
rc=$?
check "unbalanced markers: installer exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "unbalanced markers: CLAUDE.md left untouched" \
  "$(diff_is_empty "$d" CLAUDE.md)" "empty"
check "unbalanced markers: user text below still there" \
  "$(grep -c 'Never deploy on a Friday' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 7: a hand-written methodology must stop the install ---------------
# Nothing would be destroyed, but the agent would receive two cycles and could
# not tell which one wins. Incoherent beats not-installed, so: refuse.
d="$(fixture '# My rules

Every session writes a handoff in docs/handoff/ and opens with /kickoff.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
rc=$?
check "own methodology: installer exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "own methodology: nothing was installed" \
  "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "no"
# --force is the documented escape hatch for a false positive.
(cd "$d" && bash "$INSTALLER" --force >/dev/null 2>&1)
check "own methodology: --force installs anyway" \
  "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "yes"
check "own methodology: --force still left CLAUDE.md alone" \
  "$(grep -c 'Every session writes a handoff' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 8: a VERSION file that disagrees with the installer must abort -----
# VERSION is what other projects read to decide whether they are out of date.
# A wrong value there would tell every install "you are current" while they rot,
# which is the exact failure the version stamp exists to prevent.
copy="$(mktemp -d)"
cp -r "$REPO/templates" "$copy/"
cp "$REPO/install.sh" "$copy/install.sh"
printf '0.0.1\n' > "$copy/VERSION"
d="$(fixture '')"
(cd "$d" && bash "$copy/install.sh" >/dev/null 2>&1)
rc=$?
check "stale VERSION file: installer exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "stale VERSION file: nothing was installed" \
  "$(yesno "$([ -d "$d/.claude" ]; echo $?)")" "no"
rm -rf "$d" "$copy"

# --- Case 9: the session-start hook fails LOUDLY without relevio.md ---------
# This is the failure mode that killed the @import design: a methodology that
# silently is not there. The hook must say so, in words the agent will repeat.
d="$(fixture '')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
out=$(printf '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$d" bash "$d/.claude/hooks/session-start.sh" \
      | jq -r '.hookSpecificOutput.additionalContext')
check "session-start: injects the methodology" \
  "$(printf '%s' "$out" | grep -c 'Sessions and handoffs')" "1"
rm "$d/relevio.md"
out=$(printf '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$d" bash "$d/.claude/hooks/session-start.sh" \
      | jq -r '.hookSpecificOutput.additionalContext')
check "session-start: missing relevio.md is reported as an ERROR" \
  "$(printf '%s' "$out" | grep -c 'relevio ERROR')" "1"
check "session-start: missing relevio.md does not fake a methodology" \
  "$(printf '%s' "$out" | grep -c 'Sessions and handoffs')" "0"
# A reopened session must NOT get the whole file dumped into its nearly-full
# window: it gets the short revisit rules instead.
out=$(printf '{"source":"resume"}' | CLAUDE_PROJECT_DIR="$d" bash "$d/.claude/hooks/session-start.sh" \
      | jq -r '.hookSpecificOutput.additionalContext')
check "session-start: resume gets the short revisit rules" \
  "$(printf '%s' "$out" | grep -c 'REOPENED conversation')" "1"
rm -rf "$d"

# --- Case 10: uninstall removes relevio and leaves the user's files ---------
d="$(fixture '# My project

- A rule of my own.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
(cd "$d" && bash "$UNINSTALLER" >/dev/null 2>&1)
check "uninstall: relevio.md gone" "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "no"
check "uninstall: hooks gone" "$(yesno "$([ -d "$d/.claude/hooks" ]; echo $?)")" "no"
check "uninstall: the user's CLAUDE.md survived" \
  "$(grep -c 'A rule of my own' "$d/CLAUDE.md")" "1"
check "uninstall: docs/handoff kept" \
  "$(yesno "$([ -d "$d/docs/handoff" ]; echo $?)")" "yes"
rm -rf "$d"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES case(s) FAILED"
exit 1
