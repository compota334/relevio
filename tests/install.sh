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
# Since v0.20 the hooks carry the methodology themselves: no relevio.md.
check "clean install: no relevio.md is created" \
  "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "no"
check "clean install: both hooks installed" \
  "$(yesno "$([ -f "$d/.claude/hooks/session-start.sh" ] && [ -f "$d/.claude/hooks/context-warn.sh" ]; echo $?)")" "yes"
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
check "migration: the hooks now carry the methodology" \
  "$(yesno "$([ -f "$d/.claude/hooks/session-start.sh" ]; echo $?)")" "yes"
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
  "$(yesno "$([ -d "$d/.claude" ]; echo $?)")" "no"
# --force is the documented escape hatch for a false positive.
(cd "$d" && bash "$INSTALLER" --force >/dev/null 2>&1)
check "own methodology: --force installs anyway" \
  "$(yesno "$([ -f "$d/.claude/hooks/session-start.sh" ]; echo $?)")" "yes"
check "own methodology: --force still left CLAUDE.md alone" \
  "$(grep -c 'Every session writes a handoff' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 7b: the v0.18-0.19 relevio.md is removed on --update ---------------
# Those versions shipped the methodology as a relevio.md at the project root.
# Since v0.20 the hooks carry it themselves, so --update removes the leftover;
# but ONLY when the title line proves it is relevio's file. A user file that
# happens to share the name must survive.
d="$(fixture '')"
printf '# Session methodology (relevio v0.19.0)\n\nOld injected methodology.\n' > "$d/relevio.md"
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "legacy relevio.md: removed on --update" \
  "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "no"
rm -rf "$d"
d="$(fixture '')"
printf '# My own notes about relevio\n' > "$d/relevio.md"
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "legacy relevio.md: a user file with that name survives" \
  "$(grep -c 'My own notes' "$d/relevio.md")" "1"
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

# --- Case 9: what the session-start hook injects ----------------------------
# Two properties, and the second one is the reason this case exists at all.
#
# Claude Code caps how much a hook may inject. Past the cap the agent gets a
# ~2 KB preview and a file path instead of the text, with NO error visible from
# inside the session: the methodology just quietly is not there. That is
# exactly how the first attempt at v0.18 broke, piping the full 11 KB
# relevio.md through this hook and delivering its first sixth. Measured
# ceiling: ~8 KB arrives, ~12 KB does not. So every branch stays well under it,
# and this test fails if anyone grows one past the budget.
INJECT_BUDGET=6000
# Claude Code sends transcript_path on every hook event, so the helper does
# too (the value just has to be non-empty; only its presence is checked). A
# payload WITHOUT it simulates a foreign host (Devin et al.), tested below.
inject() {
  printf '{"source":"%s","transcript_path":"%s"}' "$2" "$1/.claude/hooks/session-start.sh" \
    | CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/session-start.sh" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
inject_foreign() {
  printf '{"source":"%s"}' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/session-start.sh" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
d="$(fixture '')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
out="$(inject "$d" startup)"
check "session-start: injects the session cycle" \
  "$(printf '%s' "$out" | grep -c 'relevio session cycle')" "1"
# The version travels INSIDE the injected text, so the agent can report it at
# session start and a repo running stale rules is visible immediately. It is a
# second copy of the number (the hook header carries the stamp the installer
# checks), and two copies drift: this pins them together.
check "session-start: the injected core carries the current version" \
  "$(printf '%s' "$out" | grep -c "relevio v$(tr -d '[:space:]' < "$REPO/VERSION")")" "1"
# ANTI-ANTICIPATION: nothing the agent receives before a warning may teach it
# the close-out. An agent that learns the rules (or the numbers) early anchors
# on them and starts closing before the warning arrives, wasting the very
# window the thresholds protect (observed in real sessions at 60%). So the
# core must not name the thresholds, must not speak of closing at all (a
# negation like "not a close signal" still plants the idea), and must not
# point at any file that would teach them.
check "session-start: the core does not pre-announce the close-out thresholds" \
  "$(printf '%s' "$out" | grep -cE '70%|80%|at 70|at 80')" "0"
check "session-start: the core never speaks of closing" \
  "$(printf '%s' "$out" | grep -ci 'close')" "0"
check "session-start: the core does not point at relevio.md (gone since v0.20)" \
  "$(printf '%s' "$out" | grep -c 'relevio\.md')" "0"
# The cadence promise is the one number the core MUST announce (silence is
# only information if the agent knows reports flow every ~10%). Guards the
# Claude Code path against the foreign-host variant leaking into it.
check "session-start: the core promises the checkpoint cadence" \
  "$(printf '%s' "$out" | grep -c 'every 10%')" "1"
# The checkpoints fire six times per session, so anything they say is the
# strongest anchor of all: they carry the bare number and nothing else.
cw() { # usage: cw <input_tokens> <band-tag> -> the injected message
  local fake="$d/fake-transcript.jsonl"
  printf '{"model":"claude-opus-5","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1" > "$fake"
  printf '{"transcript_path":"%s","session_id":"relevio-test-%s-%s"}' "$fake" "$$" "$2" \
    | bash "$d/.claude/hooks/context-warn.sh" | jq -r '.hookSpecificOutput.additionalContext // ""'
}
cw_out="$(cw 150000 info)"
check "context-warn: checkpoint speaks at 15%" \
  "$(printf '%s' "$cw_out" | grep -c 'no action needed')" "1"
# The message now carries token counts, so match the thresholds as
# percentages ("70%"), not bare digits a token count could contain.
check "context-warn: checkpoint does not name the close-out thresholds" \
  "$(printf '%s' "$cw_out" | grep -cE '70%|80%')" "0"
check "context-warn: checkpoint never speaks of closing or handoffs" \
  "$(printf '%s' "$cw_out" | grep -ciE 'close|handoff|wrap')" "0"
# Free tokens must be spelled out: a bare percentage reads as scarcer than it
# is (observed: an agent at 30% recommending closure "to be safe").
check "context-warn: checkpoint states the free tokens" \
  "$(printf '%s' "$cw_out" | grep -c 'still free')" "1"
# The soft warning frames the sweet spot (max understanding loaded, plenty of
# room) but must NOT ask for the handoff yet (that instruction travels with
# the hard warning), and must keep serving the user at any request size (the
# old text made agents refuse or shrink work after it).
cw_out="$(cw 720000 soft)"
check "context-warn: soft frames the sweet spot" \
  "$(printf '%s' "$cw_out" | grep -c 'sweet spot')" "1"
check "context-warn: soft does not ask for the handoff yet" \
  "$(printf '%s' "$cw_out" | grep -c 'Nothing needs to be written down yet')" "1"
check "context-warn: soft keeps serving the user" \
  "$(printf '%s' "$cw_out" | grep -c 'welcome at any size')" "1"
check "context-warn: soft ends telling the agent to keep working" \
  "$(printf '%s' "$cw_out" | grep -c 'keep working')" "1"
# The hard warning is the FIRST time the agent needs the close-out, so it must
# carry the complete checklist itself, not a pointer to something read earlier.
cw_out="$(cw 810000 hard)"
check "context-warn: hard asks for the close" \
  "$(printf '%s' "$cw_out" | grep -c 'Time to close the session')" "1"
check "context-warn: hard carries the full handoff instructions" \
  "$(printf '%s' "$cw_out" | grep -c 'docs/handoff/YYYY-MM-DD')" "1"
check "context-warn: hard tells the agent not to rush" \
  "$(printf '%s' "$cw_out" | grep -c 'no rushing, no skipped steps')" "1"
# The commit comes AFTER the handoff (step 3), never in step 1: an early
# commit order made agents cut work mid-change to obey it.
check "context-warn: hard does not ask to commit before the handoff" \
  "$(printf '%s' "$cw_out" | grep '^1\.' | grep -c 'commit')" "0"
rm -f /tmp/claude-ctx-warn-relevio-test-$$-*

# --- Case 9b: FOREIGN HOST (no transcript_path) fails LOUD, never silent ----
# Devin (and other Claude-compatible harnesses) load .claude/ hooks by default
# but send no transcript_path. Up to v0.20.1 context-warn exited silently
# there, while the session-start core PROMISED a report every ~10%: the agent
# was told to read silence as information, and the silence was structural.
# These cases pin the fix: the core stops promising, the reporter says loudly
# and exactly once that reporting is off.
out="$(inject_foreign "$d" startup)"
check "foreign host: core still injects the session cycle" \
  "$(printf '%s' "$out" | grep -c 'relevio session cycle')" "1"
check "foreign host: core does NOT promise the cadence" \
  "$(printf '%s' "$out" | grep -c 'every 10%')" "0"
check "foreign host: core says no reports will arrive" \
  "$(printf '%s' "$out" | grep -c 'NO usage reports will arrive')" "1"
check "foreign host: core forbids guessing usage" \
  "$(printf '%s' "$out" | grep -c 'Never guess or invent a usage figure')" "1"
# Anti-anticipation still holds in the foreign variant: no thresholds, no
# talk of closing (anchor percentages to the % sign, never bare digits).
check "foreign host: core does not pre-announce the close-out thresholds" \
  "$(printf '%s' "$out" | grep -cE '70%|80%')" "0"
check "foreign host: core never speaks of closing" \
  "$(printf '%s' "$out" | grep -ci 'close')" "0"
n=$(printf '%s' "$out" | wc -c)
check "foreign host: core fits the injection budget ($n <= $INJECT_BUDGET)" \
  "$([ "$n" -le "$INJECT_BUDGET" ] && echo yes || echo no)" "yes"
# context-warn without transcript_path: one loud notice, then silence.
cwf() {
  printf '{"session_id":"relevio-test-%s-foreign"}' "$$" \
    | bash "$d/.claude/hooks/context-warn.sh" | jq -r '.hookSpecificOutput.additionalContext // ""'
}
out="$(cwf)"
check "foreign host: context-warn says reporting is OFF" \
  "$(printf '%s' "$out" | grep -c 'Usage reporting is OFF')" "1"
check "foreign host: context-warn notice carries the handoff pointer" \
  "$(printf '%s' "$out" | grep -c 'docs/handoff/')" "1"
check "foreign host: context-warn speaks exactly once per session" \
  "$(cwf | wc -c | tr -d ' ')" "0"
# A transcript_path that is present but points to a missing file is a
# transient oddity, not a foreign host: stays silent (unchanged behavior).
check "foreign host: present-but-missing transcript stays silent" \
  "$(printf '{"transcript_path":"/nonexistent-relevio-test-%s","session_id":"relevio-test-%s-missing"}' "$$" "$$" \
     | bash "$d/.claude/hooks/context-warn.sh" | wc -c | tr -d ' ')" "0"
rm -f /tmp/claude-ctx-warn-relevio-test-$$-*

for src in startup resume compact; do
  n=$(printf '%s' "$(inject "$d" "$src")" | wc -c)
  check "session-start: $src payload fits the injection budget ($n <= $INJECT_BUDGET)" \
    "$([ "$n" -le "$INJECT_BUDGET" ] && echo yes || echo no)" "yes"
done
# A reopened session must NOT get the cycle rules dumped into its nearly-full
# window: it gets the short revisit rules instead.
out="$(inject "$d" resume)"
check "session-start: resume gets the short revisit rules" \
  "$(printf '%s' "$out" | grep -c 'REOPENED conversation')" "1"
rm -rf "$d"

# --- Case 10: uninstall removes relevio and leaves the user's files ---------
d="$(fixture '# My project

- A rule of my own.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
# Simulate a legacy v0.18-0.19 leftover: the uninstaller must clean it up too,
# but only because the title line proves it is relevio's.
printf '# Session methodology (relevio v0.19.0)\n\nOld.\n' > "$d/relevio.md"
(cd "$d" && bash "$UNINSTALLER" >/dev/null 2>&1)
check "uninstall: legacy relevio.md gone" "$(yesno "$([ -f "$d/relevio.md" ]; echo $?)")" "no"
check "uninstall: hooks gone" "$(yesno "$([ -d "$d/.claude/hooks" ]; echo $?)")" "no"
check "uninstall: the user's CLAUDE.md survived" \
  "$(grep -c 'A rule of my own' "$d/CLAUDE.md")" "1"
check "uninstall: docs/handoff kept" \
  "$(yesno "$([ -d "$d/docs/handoff" ]; echo $?)")" "yes"
rm -rf "$d"

# --- Case 11: the README documents what the agent receives ------------------
# With relevio.md gone, the README section "What relevio says to the agent"
# is the user-visible catalog of every injected message. If it disappears,
# the messages become invisible to users without opening the scripts.
check "README: documents the injected messages" \
  "$(grep -c 'What relevio says to the agent' "$REPO/README.md")" "1"
check "README: no longer lists relevio.md as an installed file" \
  "$(grep -c '| \`relevio.md\`' "$REPO/README.md")" "0"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES case(s) FAILED"
exit 1
