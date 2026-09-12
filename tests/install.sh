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
  # Pin the initial branch name: the host's git may default to master, and
  # these fixtures write `Branch: main` into their handoff headers.
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  # Point git at an empty hooks directory: the developer's own global hooks
  # (a commit-author guard, for instance) must not be able to change what
  # these fixtures do.
  mkdir -p "$dir/.nohooks"
  git -C "$dir" config core.hooksPath "$dir/.nohooks"
  git -C "$dir" config user.email test@relevio.local
  git -C "$dir" config user.name relevio-test
  git -C "$dir" config commit.gpgsign false
  [ -n "${1:-}" ] && printf '%s' "$1" > "$dir/CLAUDE.md"
  echo "$dir"
}

# A team repo: a bare origin, main, one MERGED feature branch and one OPEN
# one, each closing a session with a handoff. This is the shape the lane board
# and the trace exist for, and the only way to test them is to build it.
# core.hooksPath is pointed at an empty directory so the developer's own global
# git hooks (a commit-author guard, for instance) cannot block the fixture.
team_fixture() {
  local d r
  d="$(mktemp -d)"; r="$d/repo"
  git init -q --bare "$d/origin.git"
  git init -q "$r"
  git -C "$r" symbolic-ref HEAD refs/heads/main
  mkdir -p "$d/nohooks"
  git -C "$r" config core.hooksPath "$d/nohooks"
  git -C "$r" config user.email test@relevio.local
  git -C "$r" config user.name relevio-test
  git -C "$r" config commit.gpgsign false
  git -C "$r" remote add origin "$d/origin.git"
  mkdir -p "$r/src" "$r/lib" "$r/docs/handoff"

  echo a > "$r/src/a.txt"
  git -C "$r" add -A; git -C "$r" commit -qm base
  write_handoff "$r" 2026-09-01_base.md "01-09-26 base" NICO main \
    "$(git -C "$r" rev-parse --short HEAD)..$(git -C "$r" rev-parse --short HEAD)" src "base session"
  git -C "$r" add -A; git -C "$r" commit -qm "handoff base"; git -C "$r" push -q origin main

  git -C "$r" checkout -q -b feat-merged
  echo b >> "$r/src/a.txt"; git -C "$r" commit -qam "feat merged work"
  write_handoff "$r" 2026-09-02_feat-merged.md "02-09-26 feat merged" ANA feat-merged \
    "$(git -C "$r" rev-parse --short HEAD)..$(git -C "$r" rev-parse --short HEAD)" src "merged session"
  git -C "$r" add -A; git -C "$r" commit -qm "handoff feat-merged"
  git -C "$r" push -q origin feat-merged
  git -C "$r" checkout -q main
  git -C "$r" merge -q --no-ff -m "merge feat-merged" feat-merged
  git -C "$r" push -q origin main

  git -C "$r" checkout -q -b feat-open main
  echo c > "$r/lib/b.txt"; git -C "$r" add -A; git -C "$r" commit -qm "open work"
  write_handoff "$r" 2026-09-03_feat-open.md "03-09-26 feat open" JUAN feat-open \
    "$(git -C "$r" rev-parse --short HEAD)..$(git -C "$r" rev-parse --short HEAD)" lib "open session"
  git -C "$r" add -A; git -C "$r" commit -qm "handoff feat-open"
  git -C "$r" push -q origin feat-open
  git -C "$r" checkout -q main
  git -C "$r" fetch -q origin
  echo "$r"
}

# write_handoff <repo> <file> <session> <dev> <branch> <commits> <areas> <summary>
write_handoff() {
  printf 'Session: %s\nDate: %s\nDev: %s\nBranch: %s\nCommits: %s\nAreas: %s\nResume: claude --resume test\nTopics: t\nSummary: %s\n\nBody.\n' \
    "$3" "$(echo "$2" | cut -c1-10)" "$4" "$5" "$6" "$7" "$8" > "$1/docs/handoff/$2"
}

# The board section of a generated index, and the catalog section.
board_of()   { sed -n '/^## Active lanes/,/^## Catalog/p' "$1"; }
catalog_of() { sed -n '/^## Catalog/,$p' "$1" | grep '^| 20' || true; }

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
    | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/session-start.sh" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
inject_foreign() {
  printf '{"source":"%s"}' "$2" | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/session-start.sh" \
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
cw() { # usage: cw <input_tokens> <band-tag> [model] -> the injected message
  local fake="$d/fake-transcript.jsonl" model="${3:-claude-opus-5}"
  printf '{"model":"%s","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$model" "$1" > "$fake"
  printf '{"transcript_path":"%s","session_id":"relevio-test-%s-%s"}' "$fake" "$$" "$2" \
    | env -u CLAUDE_PLUGIN_ROOT bash "$d/.claude/hooks/context-warn.sh" | jq -r '.hookSpecificOutput.additionalContext // ""'
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
# GLM (Z.ai) models: the GLM Coding Plan plugs them into Claude Code, so the
# window table must know them. Same token count, different band, proves the
# window is really being applied (150k is 15% of 1M but 75% of 200k). An
# unlisted glm variant must NOT be guessed at: raw count, like any unknown.
cw_out="$(cw 150000 glm1m glm-5.2)"
check "context-warn: glm-5.2 gets the 1M window (150k is a checkpoint)" \
  "$(printf '%s' "$cw_out" | grep -c 'no action needed')" "1"
cw_out="$(cw 150000 glm200k glm-4.6)"
check "context-warn: glm-4.6 gets the 200k window (150k is the sweet spot)" \
  "$(printf '%s' "$cw_out" | grep -c 'sweet spot')" "1"
cw_out="$(cw 150000 glmunknown glm-4.5-air)"
check "context-warn: unlisted glm variant drops to raw count, no guessed window" \
  "$(printf '%s' "$cw_out" | grep -c 'cannot compute a percentage')" "1"
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
    | env -u CLAUDE_PLUGIN_ROOT bash "$d/.claude/hooks/context-warn.sh" | jq -r '.hookSpecificOutput.additionalContext // ""'
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
     | env -u CLAUDE_PLUGIN_ROOT bash "$d/.claude/hooks/context-warn.sh" | wc -c | tr -d ' ')" "0"
rm -f /tmp/claude-ctx-warn-relevio-test-$$-*

# --- Case 9c: ZCODE host (payload model "builtin:*") reads SQLite -----------
# ZCode DOES send a transcript_path, but it points at a throwaway temp file
# with no token data (the decoy), so shape-based detection cannot work: the
# reader must key off the payload model, ignore the transcript, and read the
# usage from ZCode's SQLite by session_id. Measured schema and behavior:
# docs/2026-08-26_zcode-investigation.md.
if command -v python3 >/dev/null 2>&1; then
  zdb="$d/fake-zcode.sqlite"
  python3 - "$zdb" "relevio-test-$$-zc" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE model_usage (session_id TEXT, turn_id TEXT,'
            ' model_id TEXT, computed_total_tokens INTEGER)')
con.execute('INSERT INTO model_usage VALUES (?, "t1", "GLM-5.3", 900000)',
            (sys.argv[2],))
con.execute('INSERT INTO model_usage VALUES (?, "t2", "GLM-5.3", 150000)',
            (sys.argv[2],))
con.commit()
PY
  printf '{"message":{"content":[{"text":"decoy, no usage here","type":"text"}],"role":"user"}}\n' > "$d/decoy-transcript.jsonl"
  zcw() { # usage: zcw <session-suffix> <db> -> the injected message
    printf '{"model":"builtin:zai/GLM-5.3","session_id":"relevio-test-%s-%s","transcript_path":"%s"}' "$$" "$1" "$d/decoy-transcript.jsonl" \
      | env -u CLAUDE_PLUGIN_ROOT RELEVIO_ZCODE_DB="$2" bash "$d/.claude/hooks/context-warn.sh" \
      | jq -r '.hookSpecificOutput.additionalContext // ""'
  }
  # Latest row wins (150k, not the older 900k), GLM-5.3 normalizes into the
  # window table (1M), so 150k is a 15% checkpoint and not a guard band.
  out="$(zcw zc "$zdb")"
  check "zcode: reads latest usage from sqlite and applies the GLM window" \
    "$(printf '%s' "$out" | grep -c '15% of your context window')" "1"
  check "zcode: the decoy transcript was ignored (percentage, not silence)" \
    "$(printf '%s' "$out" | grep -c 'no action needed')" "1"
  # A session with no rows yet is a normal early state: quiet, no OFF notice.
  check "zcode: no usage rows yet stays silent" \
    "$(zcw zcempty "$zdb" | wc -c | tr -d ' ')" "0"
  # A missing db is structural: the loud OFF notice, exactly once.
  out="$(zcw zcnodb /nonexistent-zcode-db-$$)"
  check "zcode: missing db fails LOUD with the OFF notice" \
    "$(printf '%s' "$out" | grep -c 'Usage reporting is OFF')" "1"
  check "zcode: the OFF notice fires only once per session" \
    "$(zcw zcnodb /nonexistent-zcode-db-$$ | wc -c | tr -d ' ')" "0"
  # session-start mirrors the capability: cadence with a readable db, the
  # OFF variant without one.
  zss() {
    printf '{"source":"startup","model":"builtin:zai/GLM-5.3"}' \
      | env -u CLAUDE_PLUGIN_ROOT RELEVIO_ZCODE_DB="$1" bash "$d/.claude/hooks/session-start.sh" \
      | jq -r '.hookSpecificOutput.additionalContext'
  }
  check "zcode: session-start promises the cadence when the db is readable" \
    "$(zss "$zdb" | grep -c 'every 10%')" "1"
  check "zcode: session-start goes OFF-variant when the db is not there" \
    "$(zss "/nonexistent-zcode-db-$$" | grep -c 'NO usage reports will arrive')" "1"
  # Command names on ZCode (measured 2026-08-26): plugin commands register
  # WITHOUT the prefix and /rename does not exist, so the hard close-out
  # must say /kickoff and must not ask for any rename command.
  python3 - "$zdb" "relevio-test-$$-zchard" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('INSERT INTO model_usage VALUES (?, "t1", "GLM-5.3", 810000)',
            (sys.argv[2],))
con.commit()
PY
  out="$(zcw zchard "$zdb")"
  check "zcode: 81% fires the hard close-out" \
    "$(printf '%s' "$out" | grep -c 'Time to close the session')" "1"
  # Presence AND absence: an absence-only check would also pass on an empty
  # or kickoff-less message, unguarding the very name this release pins.
  check "zcode: hard close-out names plain '/kickoff'" \
    "$(printf '%s' "$out" | grep -q "'/kickoff'" && echo yes || echo no)" "yes"
  check "zcode: hard close-out has no namespaced command" \
    "$(printf '%s' "$out" | grep -q 'relevio:kickoff' && echo yes || echo no)" "no"
  check "zcode: hard close-out never asks for /rename" \
    "$(printf '%s' "$out" | grep -q '/rename' && echo yes || echo no)" "no"
  # ZCode has no rename command, but the agent CAN rename the task itself by
  # updating ZCode's session table (verified live 2026-08-26: the UI shows
  # the new title). The close-out must carry that instruction, fail-loud.
  check "zcode: hard close-out has the agent rename the task itself" \
    "$(printf '%s' "$out" | grep -q 'Rename this ZCode task YOURSELF' && echo yes || echo no)" "yes"
  zss_out="$(zss "$zdb")"
  check "zcode: session-start core names plain /kickoff" \
    "$(printf '%s' "$zss_out" | grep -q 'start with /kickoff' && echo yes || echo no)" "yes"
  check "zcode: session-start core has no namespaced command" \
    "$(printf '%s' "$zss_out" | grep -q 'relevio:kickoff' && echo yes || echo no)" "no"
  rm -f /tmp/claude-ctx-warn-relevio-test-$$-*
else
  echo "  SKIP  zcode cases (python3 not available)"
fi

# --- Case 9d: command names per host/install mode ---------------------------
# The hooks resolve the kickoff command name at RUNTIME: Claude Code plugin
# installs (CLAUDE_PLUGIN_ROOT set, no builtin model) say /relevio:kickoff;
# script installs (no CLAUDE_PLUGIN_ROOT) say /kickoff. hooks/ and templates/
# are the same file since v0.21.3: the old sed namespace transform is gone.
out="$(printf '{"source":"startup","transcript_path":"%s"}' "$REPO/VERSION" \
  | CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/session-start.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')"
check "plugin-on-claude: core names /relevio:kickoff" \
  "$(printf '%s' "$out" | grep -q 'start with /relevio:kickoff' && echo yes || echo no)" "yes"
out="$(inject "$d" startup)"
check "script install: core names plain /kickoff" \
  "$(printf '%s' "$out" | grep -q 'start with /kickoff' && echo yes || echo no)" "yes"
check "script install: core has no namespaced command" \
  "$(printf '%s' "$out" | grep -q 'relevio:kickoff' && echo yes || echo no)" "no"
fake="$d/fake-transcript.jsonl"
printf '{"model":"claude-opus-5","message":{"usage":{"input_tokens":810000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$fake"
out="$(printf '{"transcript_path":"%s","session_id":"relevio-test-%s-plughard"}' "$fake" "$$" \
  | CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/context-warn.sh" \
  | jq -r '.hookSpecificOutput.additionalContext // ""')"
check "plugin-on-claude: hard close-out keeps /rename" \
  "$(printf '%s' "$out" | grep -q '/rename DD-MM-YY' && echo yes || echo no)" "yes"
check "plugin-on-claude: hard close-out namespaced kickoff present" \
  "$(printf '%s' "$out" | grep -q "'/relevio:kickoff'" && echo yes || echo no)" "yes"
# INDEX.md is generated since v0.22, so the close-out must send the agent to
# the script rather than telling it to append a row by hand, and the path it
# names has to match the host it is running on.
out="$(printf '{"source":"startup","transcript_path":"%s"}' "$REPO/VERSION" \
  | CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/context-warn.sh" >/dev/null 2>&1; \
  printf '{"model":"claude-opus-5","message":{"usage":{"input_tokens":810000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$d/plug-transcript.jsonl"; \
  printf '{"transcript_path":"%s","session_id":"relevio-test-%s-plugidx"}' "$d/plug-transcript.jsonl" "$$" \
  | CLAUDE_PLUGIN_ROOT="$REPO" bash "$REPO/hooks/context-warn.sh" \
  | jq -r '.hookSpecificOutput.additionalContext // ""')"
check "plugin-on-claude: the close-out points at the plugin's index script" \
  "$(printf '%s' "$out" | grep -c 'CLAUDE_PLUGIN_ROOT/scripts/relevio-index.sh')" "1"
check "close-out: nobody is told to append an index row by hand any more" \
  "$(grep -c 'append a row to docs/handoff/INDEX.md' "$REPO/hooks/context-warn.sh" "$REPO/hooks/session-start.sh" | awk -F: '{ s += $2 } END { print s }')" "0"
check "close-out: the handoff header fields it names include Areas" \
  "$(printf '%s' "$out" | grep -c 'Branch, Commits and Areas')" "1"
rm -f /tmp/claude-ctx-warn-relevio-test-$$-plugidx
out="$(cw 810000 scridx)"
check "script install: the close-out points at .claude/scripts/relevio-index.sh" \
  "$(printf '%s' "$out" | grep -c 'bash .claude/scripts/relevio-index.sh')" "1"
check "session-start: the core describes kickoff as reading YOUR branch" \
  "$(inject "$d" startup | grep -c 'latest handoff OF YOUR OWN BRANCH')" "1"
check "hooks/ and templates/ scripts are identical (no more sed transform)" \
  "$(diff -q "$REPO/hooks/context-warn.sh" "$REPO/templates/context-warn.sh" >/dev/null && diff -q "$REPO/hooks/session-start.sh" "$REPO/templates/session-start.sh" >/dev/null && echo same)" "same"
# The ZCode db default lives in TWO scripts that cannot share a variable; if
# they ever disagree, session-start promises reports context-warn cannot
# deliver (or vice versa). Pin them to the same literal.
check "zcode db default path identical in both scripts" \
  "$(grep -o 'RELEVIO_ZCODE_DB:-[^}]*' "$REPO/templates/context-warn.sh" | sort -u)" \
  "$(grep -o 'RELEVIO_ZCODE_DB:-[^}]*' "$REPO/templates/session-start.sh" | sort -u)"
rm -f /tmp/claude-ctx-warn-relevio-test-$$-*

# --- Case 9e: regressions pinned by the v0.21.3 code review -----------------
# A session_id containing "/" used to break every /tmp marker write, which
# silenced all bands AND the fail-loud notice; the marker name now sanitizes
# the id (the raw id still keys the db query).
out="$(printf '{"session_id":"relevio-test/%s-slash"}' "$$" \
  | env -u CLAUDE_PLUGIN_ROOT bash "$d/.claude/hooks/context-warn.sh" \
  | jq -r '.hookSpecificOutput.additionalContext // ""')"
check "slash in session_id: off_notice still speaks" \
  "$(printf '%s' "$out" | grep -q 'Usage reporting is OFF' && echo yes || echo no)" "yes"
# A haiku id carrying the 1M tag must resolve to the 1M window (the [1m]
# group is matched before the haiku family row).
cw_out="$(cw 150000 haiku1m 'claude-haiku-4-5[1m]')"
check "haiku[1m]: the 1M tag outranks the haiku 200k row" \
  "$(printf '%s' "$cw_out" | grep -q '15% of your context window' && echo yes || echo no)" "yes"
if command -v python3 >/dev/null 2>&1; then
  # A db path containing %xx used to be percent-decoded by sqlite's URI
  # parser, failing a healthy db into the OFF notice; the path is now quoted.
  pdir="$d/pct%31dir"; mkdir -p "$pdir"; cp "$zdb" "$pdir/db.sqlite"
  python3 - "$pdir/db.sqlite" "relevio-test-$$-pct" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('INSERT INTO model_usage VALUES (?, "t1", "GLM-5.3", 150000)',
            (sys.argv[2],))
con.commit()
PY
  out="$(printf '{"model":"builtin:zai/GLM-5.3","session_id":"relevio-test-%s-pct"}' "$$" \
    | env -u CLAUDE_PLUGIN_ROOT RELEVIO_ZCODE_DB="$pdir/db.sqlite" bash "$d/.claude/hooks/context-warn.sh" \
    | jq -r '.hookSpecificOutput.additionalContext // ""')"
  check "percent in db path: healthy db still yields a percentage" \
    "$(printf '%s' "$out" | grep -q '15% of your context window' && echo yes || echo no)" "yes"
  # ZCode's second fingerprint: the decoy transcript path routes to the
  # sqlite reader even if a future ZCode stops sending the model field.
  dec="$d/zcode-claude-hook-fake"; mkdir -p "$dec"; cp "$d/decoy-transcript.jsonl" "$dec/transcript.jsonl"
  python3 - "$zdb" "relevio-test-$$-decoy" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('INSERT INTO model_usage VALUES (?, "t1", "GLM-5.3", 150000)',
            (sys.argv[2],))
con.commit()
PY
  out="$(printf '{"session_id":"relevio-test-%s-decoy","transcript_path":"%s/transcript.jsonl"}' "$$" "$dec" \
    | env -u CLAUDE_PLUGIN_ROOT RELEVIO_ZCODE_DB="$zdb" bash "$d/.claude/hooks/context-warn.sh" \
    | jq -r '.hookSpecificOutput.additionalContext // ""')"
  # Without a model field the window cannot be sized, so the correct outcome
  # is RAW-COUNT mode fed by the sqlite reader: the 150000 figure can only
  # come from the db (the decoy transcript carries no usage), which proves
  # the decoy-path fingerprint routed to the right reader.
  check "zcode decoy path alone (no model field) still reads the sqlite usage" \
    "$(printf '%s' "$out" | grep -q '150000 tokens of your context window used so far' && echo yes || echo no)" "yes"
  # session-start must not promise the cadence on a db that cannot answer:
  # a zero-length file passes [ -f ] but has no model_usage table.
  : > "$d/empty.sqlite"
  check "zcode: unanswerable db gets the OFF variant, not the promise" \
    "$(zss "$d/empty.sqlite" | grep -q 'NO usage reports will arrive' && echo yes || echo no)" "yes"
fi
rm -f /tmp/claude-ctx-warn-relevio-test*

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

# --- Case 12: the lane board, the catalog and the surface trace -------------
# relevio's original model was one timeline: "the latest handoff" was global.
# With a team on several branches that answer is somebody else's session. The
# index is now GENERATED from every handoff on every ref, split into the lanes
# that are still open and the full catalog; the trace answers "who was on this
# surface, and who is on it right now".
IDX="$REPO/scripts/relevio-index.sh"
TRC="$REPO/scripts/relevio-trace.sh"
d="$(team_fixture)"
idx="$d/docs/handoff/INDEX.md"

( cd "$d" && bash "$IDX" >/dev/null 2>&1 )
check "index: exits 0 on a healthy team repo" "$?" "0"
check "index: the open branch is the only lane on the board" \
  "$(board_of "$idx" | grep -c '^| `feat-open`')" "1"
check "index: the merged branch is absent from the board" \
  "$(board_of "$idx" | grep -c 'feat-merged')" "0"
check "index: main is never a lane" \
  "$(board_of "$idx" | grep -c '^| `main`')" "0"
# Two commits ahead: the work commit and the handoff commit.
check "index: the lane reports how far ahead of main it is" \
  "$(board_of "$idx" | awk -F'|' '/feat-open/ { gsub(/ /, "", $6); print $6 }')" "2"
check "index: the lane names the dev who owns it" \
  "$(board_of "$idx" | grep -c 'JUAN')" "1"
check "index: the catalog holds every session, in filename order" \
  "$(catalog_of "$idx" | awk -F'|' '{ gsub(/ /, "", $4); print $4 }' | paste -sd, -)" \
  "2026-09-01_base.md,2026-09-02_feat-merged.md,2026-09-03_feat-open.md"
# The point of reading handoffs across refs: main is checked out, so the open
# branch's handoff is not in this working tree at all, yet it is catalogued.
check "index: a handoff living only on another branch is still catalogued" \
  "$(yesno "$([ -f "$d/docs/handoff/2026-09-03_feat-open.md" ]; echo $?)")" "no"
check "index: ... and its row carries that branch" \
  "$(catalog_of "$idx" | grep -c '2026-09-03_feat-open.md | JUAN | `feat-open`')" "1"

# /handoff regenerates the index BEFORE committing, so the handoff it just
# wrote exists only in the working tree. It must still be catalogued.
write_handoff "$d" 2026-09-04_uncommitted.md "04-09-26 uncommitted" NICO main none none "not committed yet"
( cd "$d" && bash "$IDX" >/dev/null 2>&1 )
check "index: an uncommitted handoff in the working tree is catalogued" \
  "$(catalog_of "$idx" | grep -c '2026-09-04_uncommitted.md')" "1"
rm "$d/docs/handoff/2026-09-04_uncommitted.md"

# Idempotency: the generated file carries no timestamp, so regenerating it
# without new sessions must produce a byte-identical file. A file that always
# reports a change is a file whose diff people stop reading.
( cd "$d" && bash "$IDX" >/dev/null 2>&1 )
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm "index" >/dev/null 2>&1
( cd "$d" && bash "$IDX" >/dev/null 2>&1 )
check "index: regenerating without new sessions leaves no diff" \
  "$(diff_is_empty "$d" docs/handoff/INDEX.md)" "empty"

# Fail-loud: a malformed header aborts the whole run naming the file and the
# field, and leaves the previous index untouched. A partial index would
# silently drop a session, which is the one thing this file must never do.
before="$(cat "$idx")"
write_handoff "$d" 2026-09-05_bad.md "05-09-26 bad" NICO "main (via worktree)" none none "prose in Branch"
err="$( (cd "$d" && bash "$IDX" >/dev/null) 2>&1 )"; rc=$?
check "index: prose in Branch fails loud" "$rc" "2"
check "index: ... naming the file and the field" \
  "$(printf '%s' "$err" | grep -c '2026-09-05_bad.md: Branch:')" "1"
check "index: ... and leaves INDEX.md untouched" \
  "$(yesno "$([ "$before" = "$(cat "$idx")" ]; echo $?)")" "yes"
rm "$d/docs/handoff/2026-09-05_bad.md"

write_handoff "$d" 2026-09-05_bad.md "05-09-26 bad" NICO main "abc1234..def5678 (10 commits)" none "suffix in Commits"
err="$( (cd "$d" && bash "$IDX" >/dev/null) 2>&1 )"
check "index: a \"(N commits)\" suffix fails loud and points at the migration" \
  "$(printf '%s' "$err" | grep -c 'relevio-migrate.sh')" "1"
rm "$d/docs/handoff/2026-09-05_bad.md"

# A pre-v0.22 header has no Areas field. The error must say so in those words,
# because the fix is a migration, not a hand edit.
printf 'Session: s\nDate: 2026-09-05\nDev: N\nBranch: main\nCommits: none\nResume: r\nTopics: t\nSummary: s\n\nB.\n' \
  > "$d/docs/handoff/2026-09-05_legacy.md"
err="$( (cd "$d" && bash "$IDX" >/dev/null) 2>&1 )"
check "index: a pre-v0.22 header names the migration script" \
  "$(printf '%s' "$err" | grep -c 'predates relevio v0.22')" "1"
rm "$d/docs/handoff/2026-09-05_legacy.md"

# The integration branch is never guessed. A repo that HAS commits but no
# origin cannot have its lanes measured, so it stops and says so.
d2="$(fixture '')"
mkdir -p "$d2/docs/handoff"
write_handoff "$d2" 2026-09-01_solo.md "01-09-26 solo" NICO main none none "solo"
git -C "$d2" add -A >/dev/null 2>&1; git -C "$d2" commit -qm first >/dev/null 2>&1
err="$( (cd "$d2" && bash "$IDX" >/dev/null) 2>&1 )"; rc=$?
check "index: no origin/main fails loud instead of guessing" "$rc" "2"
check "index: ... and says which ref it looked for" \
  "$(printf '%s' "$err" | grep -c 'refs/remotes/origin/main')" "1"
( cd "$d2" && RELEVIO_MAIN=main bash "$IDX" >/dev/null 2>&1 )
check "index: RELEVIO_MAIN points it at a repo with no remote" "$?" "0"
rm -rf "$d2"

# A repository with no commits at all is a real state, not a missing ref: the
# very first session of a brand new repo must be able to close.
d3="$(fixture '')"
mkdir -p "$d3/docs/handoff"
write_handoff "$d3" 2026-09-01_first.md "01-09-26 first" NICO main none none "the very first session"
( cd "$d3" && bash "$IDX" >/dev/null 2>&1 )
check "index: a repo with no commits yet still builds its catalog" "$?" "0"
check "index: ... and the board says why it is empty" \
  "$(board_of "$d3/docs/handoff/INDEX.md" | grep -c 'no commits yet')" "1"
check "index: ... with the first session listed" \
  "$(catalog_of "$d3/docs/handoff/INDEX.md" | grep -c '2026-09-01_first.md')" "1"
rm -rf "$d3"

# The trace. src was touched by two sessions, both merged: no collision risk.
out="$( cd "$d" && bash "$TRC" src 2>&1 )"
check "trace: src reports both prior sessions" \
  "$(printf '%s' "$out" | grep -c '^| handoff ')" "2"
check "trace: both are marked merged" \
  "$(printf '%s' "$out" | grep -c 'merged |')" "2"
check "trace: src carries no open work" \
  "$(printf '%s' "$out" | grep -c 'OPEN WORK')" "0"
# lib is the dangerous one: an unmerged branch is sitting on it right now.
out="$( cd "$d" && bash "$TRC" lib 2>&1 )"
check "trace: lib flags the unmerged branch as a collision risk" \
  "$(printf '%s' "$out" | grep -c 'OPEN WORK | `feat-open`')" "1"
check "trace: ... and names who is in there" \
  "$(printf '%s' "$out" | grep -c 'JUAN')" "2"
# Every fixture range is a single commit (first == last). git's a..b excludes
# a, so without the first^..last resolution these would all report nothing.
check "trace: an inclusive single-commit range still reports its handoff" \
  "$(printf '%s' "$out" | grep -c '^| handoff | `feat-open`')" "1"
out="$( cd "$d" && bash "$TRC" nothing/here 2>&1 )"
check "trace: an untouched path says so instead of printing an empty table" \
  "$(printf '%s' "$out" | grep -c 'No handoff and no open branch touched')" "1"

# A project with relevio installed but no session closed yet must still be
# able to build its index, and what it gets must be what templates/INDEX.md
# promises. The prose is the part users read to learn the file is generated;
# pinning it here keeps the template from drifting away from the script.
d4="$(fixture '')"
echo x > "$d4/README.md"
git -C "$d4" add -A >/dev/null 2>&1; git -C "$d4" commit -qm init >/dev/null 2>&1
( cd "$d4" && RELEVIO_MAIN=main bash "$IDX" >/dev/null 2>&1 )
check "index: a project with no handoffs yet still builds an index" "$?" "0"
check "index: ... which says so instead of printing an empty table" \
  "$(grep -c 'No handoffs yet' "$d4/docs/handoff/INDEX.md")" "1"
check "index: the INDEX template carries the same prose the script writes" \
  "$(diff <(sed -n '1,/^## Active lanes$/p' "$d4/docs/handoff/INDEX.md") \
          <(sed -n '1,/^## Active lanes$/p' "$REPO/templates/INDEX.md") >/dev/null && echo same)" "same"
check "index: the template no longer calls the index append-only" \
  "$(grep -c 'append-only' "$REPO/templates/INDEX.md")" "0"
rm -rf "$d4"

# A branch deleted before merging takes its handoff with it: git can no longer
# reach the file, so the row is gone. This is the documented trade-off of
# deriving the index from git rather than hand-maintaining it. Last, because
# it destroys the fixture's third session.
git -C "$d" push -q origin --delete feat-open >/dev/null 2>&1
git -C "$d" branch -qD feat-open >/dev/null 2>&1
( cd "$d" && bash "$IDX" >/dev/null 2>&1 )
check "index: a branch deleted before merging drops off the board" \
  "$(board_of "$idx" | grep -c 'No active lanes')" "1"
check "index: ... and its unmerged handoff leaves the catalog with it" \
  "$(catalog_of "$idx" | grep -c '2026-09-03_feat-open.md')" "0"
rm -rf "$d"

# --- Case 13: the one-time migration of pre-v0.22 headers -------------------
# Other projects (and other people) are running relevio v0.21 and older, where
# Branch could carry prose and Commits a "(N commits)" suffix. There is no
# tolerant parser for that: there is one migration, run once per repo, and
# after it there is a single header format.
MIG="$REPO/scripts/relevio-migrate.sh"
d="$(fixture '')"
mkdir -p "$d/docs/handoff" "$d/src" "$d/lib"
echo a > "$d/src/a.txt"; echo b > "$d/lib/b.txt"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm base >/dev/null 2>&1
h="$(git -C "$d" rev-parse --short HEAD)"
# A v0.21 header: prose in Branch, a suffix in Commits, no Areas at all.
legacy_handoff() {
  printf 'Session: %s\nDate: %s\nDev: NICO\nBranch: %s\nCommits: %s\nResume: claude --resume old\nTopics: t\nSummary: s\n\n## 1. Body\n\nText.\n' \
    "$3" "$(echo "$2" | cut -c1-10)" "$4" "$5" > "$1/docs/handoff/$2"
}
legacy_handoff "$d" 2026-08-01_one.md "01-08-26 one" "main (worked from a worktree, all pushed)" "$h..$h"
legacy_handoff "$d" 2026-08-02_two.md "02-08-26 two" "main (no open branches)" "$h..$h (10 commits)"
legacy_handoff "$d" 2026-08-03_three.md "03-08-26 three" "main" "deadbee..f00dcaf"

before="$(cat "$d/docs/handoff/2026-08-01_one.md")"
( cd "$d" && bash "$MIG" --dry-run >/dev/null 2>&1 )
check "migrate: --dry-run changes nothing on disk" \
  "$(yesno "$([ "$before" = "$(cat "$d/docs/handoff/2026-08-01_one.md")" ]; echo $?)")" "yes"

out="$( (cd "$d" && bash "$MIG") 2>&1 )"; rc=$?
# The third handoff's range does not resolve, so its Areas cannot be derived.
# Deriving it anyway, or defaulting it to "none", would write a wrong answer
# into the field the lane board reads. It is reported instead.
check "migrate: exits non-zero when a file needs a hand" "$rc" "2"
check "migrate: ... naming that file and why" \
  "$(printf '%s' "$out" | grep -c '2026-08-03_three.md: the range .* no longer resolves')" "1"
check "migrate: the other two are converted" \
  "$(printf '%s' "$out" | grep -c '^  fixed  ')" "2"
check "migrate: prose leaves Branch bare" \
  "$(grep -c '^Branch: main$' "$d/docs/handoff/2026-08-01_one.md")" "1"
check "migrate: ... and is kept in the body, not thrown away" \
  "$(grep -c '^Branch note: worked from a worktree, all pushed$' "$d/docs/handoff/2026-08-01_one.md")" "1"
check "migrate: the \"(10 commits)\" suffix is dropped" \
  "$(grep -c "^Commits: $h..$h\$" "$d/docs/handoff/2026-08-02_two.md")" "1"
check "migrate: Areas is derived from the commit range, not invented" \
  "$(grep '^Areas: ' "$d/docs/handoff/2026-08-01_one.md")" "Areas: lib/b.txt, src/a.txt"
check "migrate: Areas lands right after Commits" \
  "$(grep -A1 '^Commits: ' "$d/docs/handoff/2026-08-01_one.md" | tail -1 | cut -d: -f1)" "Areas"
check "migrate: the body survives the rewrite" \
  "$(grep -c '^## 1. Body$' "$d/docs/handoff/2026-08-01_one.md")" "1"

# A session that touched dozens of files would make an unreadable board row,
# so those collapse to their top-level directory.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
  mkdir -p "$d/area$i"; echo x > "$d/area$i/f.txt"
done
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm wide >/dev/null 2>&1
h2="$(git -C "$d" rev-parse --short HEAD)"
legacy_handoff "$d" 2026-08-04_wide.md "04-08-26 wide" "main" "$h2..$h2"
( cd "$d" && bash "$MIG" >/dev/null 2>&1 )
check "migrate: a wide session collapses its areas to directories" \
  "$(grep '^Areas: ' "$d/docs/handoff/2026-08-04_wide.md" | grep -c 'area1, area10')" "1"
check "migrate: ... without keeping the file names" \
  "$(grep -c 'f.txt' "$d/docs/handoff/2026-08-04_wide.md")" "0"

# Running it again must be a no-op: the converted files are already
# current, and the third still needs the same hand.
out2="$( (cd "$d" && bash "$MIG") 2>&1 )"
check "migrate: a second run converts nothing" \
  "$(printf '%s' "$out2" | grep -c '^  fixed  ')" "0"
check "migrate: ... and reports the converted ones as already current" \
  "$(printf '%s' "$out2" | grep -c 'already a v0.22 header')" "3"

# Once the last file is fixed by hand, the index builds.
printf 'Areas: none\n' > /dev/null
sed 's/^Commits: deadbee..f00dcaf$/Commits: none\nAreas: none/' "$d/docs/handoff/2026-08-03_three.md" > "$d/t" && mv "$d/t" "$d/docs/handoff/2026-08-03_three.md"
( cd "$d" && bash "$MIG" >/dev/null 2>&1 )
check "migrate: exits 0 once every handoff is current" "$?" "0"
( cd "$d" && RELEVIO_MAIN=main bash "$IDX" >/dev/null 2>&1 )
check "migrate: a migrated repo indexes cleanly" "$?" "0"
check "migrate: ... with every session in the catalog" \
  "$(catalog_of "$d/docs/handoff/INDEX.md" | grep -c '^| 2026-08-0')" "4"
rm -rf "$d"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES case(s) FAILED"
exit 1
