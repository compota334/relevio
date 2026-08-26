#!/usr/bin/env bash
# relevio installer
# Installs the session methodology for Claude Code into the CURRENT directory
# (your project root).
#
# relevio does NOT write to your CLAUDE.md. The methodology reaches the agent
# through two hooks and three slash commands, and nothing else is installed.
# CLAUDE.md is yours: relevio never reads it, never edits it and never depends
# on it. The exceptions are one-time MIGRATIONS: installs from v0.17 and
# earlier kept the methodology inside CLAUDE.md between markers, and v0.18-0.19
# installs shipped a relevio.md at the project root; --update removes both
# leftovers so you are not left running two copies of the rules.
set -euo pipefail

VERSION="0.21.5"
REPO_RAW="https://raw.githubusercontent.com/compota334/relevio/main"
TEMPLATES=(context-warn.sh session-start.sh handoff.md kickoff.md revisit.md INDEX.md)
STAMPED=(context-warn.sh session-start.sh)
# Legacy markers: only ever used to REMOVE the pre-v0.18 block from CLAUDE.md.
MARK_START="<!-- relevio:start -->"
MARK_END="<!-- relevio:end -->"
GI_START="# >>> relevio private mode >>>"
GI_END="# <<< relevio private mode <<<"

usage() {
  cat <<EOF
relevio v${VERSION} installer

Usage (from YOUR project root, which must be a git repository):
  curl -fsSL ${REPO_RAW}/install.sh | bash
  curl -fsSL ${REPO_RAW}/install.sh | bash -s -- --update
  bash /path/to/relevio/install.sh [--update|--force] [--private]

Options:
  --update   Upgrade an existing install to this version: refreshes the hooks
             and the slash commands. This is what you want to move from an
             older relevio to this one. All safety checks stay ON. It also
             removes leftovers from older layouts: the pre-v0.18 block inside
             CLAUDE.md (nothing else in that file is touched) and the
             v0.18-0.19 relevio.md at the project root.
  --force    Everything --update does, PLUS it overrides the safety check that
             stops the install when your CLAUDE.md already describes a session
             methodology of its own. Use only when you know that check is a
             false positive. Neither flag ever touches docs/handoff/ or
             INDEX.md.
  --private  Also add .claude/ and docs/handoff/ to .gitignore (solo mode:
             the methodology stays local, out of the repo). Without it, the
             files are left for you to commit (team mode).
  --help     This text.

WHAT BELONGS TO WHOM: the hooks in .claude/hooks/ and the slash commands in
.claude/commands/ are relevio's and are REPLACED whole on --update, so never
write your own instructions in them. CLAUDE.md is yours and relevio does not
touch it.

Uninstall:
  curl -fsSL ${REPO_RAW}/uninstall.sh | bash
EOF
}

FORCE=0
UPDATE=0
PRIVATE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1; UPDATE=1 ;;   # --force is --update plus bypassing the guard
    --update) UPDATE=1 ;;
    --private) PRIVATE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

echo "relevio v${VERSION} installer"
echo "Target project: $(pwd)"
echo

# --- Preconditions (fail loud, never install half-broken) -------------------
command -v jq >/dev/null 2>&1 || fail "jq is required (the hooks parse their input with it).
       Install it first: sudo apt install jq   |   brew install jq"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "this directory is not a git repository.
       The methodology relies on commits, pushes and handoff history.
       cd into your project, or run 'git init' first."

# relevio no longer writes into CLAUDE.md, so it can no longer overwrite what
# you wrote there. But a CLAUDE.md that already defines a session methodology
# BY HAND still collides with the one relevio injects at session start: the
# agent ends up with two cycles and two handoff schemes and cannot tell which
# wins. Nothing is destroyed in that scenario, yet the agent is left
# incoherent, which is worse than not installing. Detect it before writing
# anything, and let the human resolve it.
if [ "$FORCE" -ne 1 ] && [ -f CLAUDE.md ] && ! grep -qF "$MARK_START" CLAUDE.md \
   && grep -qEi 'docs/handoff|/kickoff|/handoff' CLAUDE.md; then
  fail "CLAUDE.md already describes a session/handoff methodology of its own.
       relevio would inject a SECOND one at every session start, leaving your
       agent with two conflicting cycles and no way to tell which one wins.
       Nothing has been installed.

       Pick one:

       (a) KEEP YOURS as the source of truth: do not install relevio's
           methodology at all. If you only want the context-window hook, copy
           it yourself and register it:
             mkdir -p .claude/hooks
             cp <relevio>/templates/context-warn.sh .claude/hooks/
           then add it as a PostToolUse hook in .claude/settings.json. Port
           relevio's newer ideas into your own text by hand.

       (b) REPLACE yours with relevio's: delete the session methodology from
           CLAUDE.md, then re-run. relevio's rules live in its own hooks and
           slash commands, and from then on --update refreshes those alone
           while CLAUDE.md stays entirely yours.

       (c) FALSE POSITIVE (your CLAUDE.md mentions handoffs for unrelated
           reasons): re-run with --force to install anyway."
fi

# --- Locate templates: local clone, or fetch from GitHub --------------------
SRC="${BASH_SOURCE[0]:-}"
if [ -n "$SRC" ] && [ -f "$(dirname "$SRC")/templates/context-warn.sh" ]; then
  TPL="$(cd "$(dirname "$SRC")/templates" && pwd)"
  [ "$(dirname "$TPL")" = "$(pwd)" ] && fail "you are running the installer inside the relevio repo itself.
       cd into YOUR project first, then run: bash $(pwd)/install.sh"
  info "using local templates: $TPL"
else
  command -v curl >/dev/null 2>&1 || fail "curl is required for the remote install."
  TPL="$(mktemp -d)"
  trap 'rm -rf "$TPL"' EXIT
  for f in "${TEMPLATES[@]}"; do
    curl -fsSL "$REPO_RAW/templates/$f" -o "$TPL/$f" \
      || fail "could not download $f from $REPO_RAW"
  done
  info "downloaded templates from GitHub"
fi

# The installed artifacts carry a version stamp so anyone can tell, offline and
# at a glance, which relevio a repo is running (a repo silently four versions
# behind is how a stale model table ends up lying about the context window).
# The stamps are the only copy the user ever sees, so a stamp that disagrees
# with this installer is a packaging bug: fail loud instead of stamping a lie.
for stamped in "${STAMPED[@]}"; do
  grep -qF "relevio v${VERSION}" "$TPL/$stamped" \
    || fail "template $stamped is not stamped 'relevio v${VERSION}'.
       This installer and its templates come from different versions, so the
       version recorded in your project would be wrong. Nothing was installed.
       Re-download a matching pair (installer + templates) and try again."
done

# The VERSION file at the repo root is what installed projects query to find out
# whether they are behind ("is there a newer relevio?"). If it disagreed with
# this installer it would tell every project the wrong answer, so it is checked
# with the same suspicion as the stamps. Only present in a local clone.
if [ -f "$(dirname "$TPL")/VERSION" ]; then
  published="$(tr -d '[:space:]' < "$(dirname "$TPL")/VERSION")"
  [ "$published" = "$VERSION" ] \
    || fail "the VERSION file says '$published' but this installer is v${VERSION}.
       VERSION is what other projects read to decide whether they are out of
       date, so a wrong value there misinforms every install. Nothing was
       installed. Make them match, then re-run."
fi
echo

# --- Helper: copy a template, refusing to clobber local edits ---------------
install_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    info "unchanged: $dest"
    return 0
  fi
  if [ -f "$dest" ] && [ "$UPDATE" -ne 1 ]; then
    fail "$dest already exists and differs from the template.
       Re-run with --update to refresh it to this version (any local edits you
       made to THIS file will be lost; your CLAUDE.md is not affected)."
  fi
  cp "$src" "$dest"
  chmod "$mode" "$dest"
  info "installed: $dest"
}

# --- 1. The hooks and slash commands ----------------------------------------
mkdir -p .claude/hooks .claude/commands
install_file "$TPL/context-warn.sh" .claude/hooks/context-warn.sh 755
install_file "$TPL/session-start.sh" .claude/hooks/session-start.sh 755
install_file "$TPL/handoff.md" .claude/commands/handoff.md 644
install_file "$TPL/kickoff.md" .claude/commands/kickoff.md 644
install_file "$TPL/revisit.md" .claude/commands/revisit.md 644

# --- 2. Register both hooks in .claude/settings.json (merge, don't clobber) --
# PostToolUse/context-warn.sh keeps the agent aware of its context window;
# SessionStart/session-start.sh delivers the session cycle at session start.
# Without the second one the agent never learns the cycle exists.
SETTINGS=".claude/settings.json"
register_hook() {
  local event="$1" script="$2"
  local entry
  entry=$(jq -nc --arg cmd "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/$script" \
    '{"matcher":"*","hooks":[{"type":"command","command":$cmd}]}')
  if [ ! -f "$SETTINGS" ]; then
    jq -n --arg ev "$event" --argjson e "$entry" '{"hooks":{($ev):[$e]}}' > "$SETTINGS"
    info "installed: $SETTINGS ($event registered)"
    return 0
  fi
  jq -e . "$SETTINGS" >/dev/null 2>&1 || fail "$SETTINGS exists but is not valid JSON. Fix it, then re-run."
  if jq -e --arg ev "$event" --arg s "$script" \
       '.hooks[$ev][]?.hooks[]?.command // empty | select(contains($s))' \
       "$SETTINGS" >/dev/null 2>&1; then
    info "unchanged: $SETTINGS ($event already registered)"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  jq --arg ev "$event" --argjson e "$entry" \
     '.hooks[$ev] = ((.hooks[$ev] // []) + [$e])' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  info "updated: $SETTINGS ($event registered, existing settings preserved)"
}
register_hook PostToolUse context-warn.sh
register_hook SessionStart session-start.sh

# --- 3. Migration: drop the pre-v0.18 block from CLAUDE.md ------------------
# Up to v0.17 the methodology lived inside CLAUDE.md between markers. Leaving
# that block behind would mean two copies of the rules in context, one of them
# frozen at whatever version it was installed at. It is removed rather than
# refreshed, because from now on CLAUDE.md belongs to the user alone.
#
# Balanced markers are a precondition, not an assumption: with a missing or
# duplicated marker there is no way to tell where the old block ends, and
# cutting blind would swallow whatever follows. Check first and refuse.
if [ -f CLAUDE.md ] && grep -qF "$MARK_START" CLAUDE.md; then
  if [ "$UPDATE" -eq 1 ]; then
    n_start=$(grep -cF "$MARK_START" CLAUDE.md || true)
    n_end=$(grep -cF "$MARK_END" CLAUDE.md || true)
    if [ "$n_start" -ne 1 ] || [ "$n_end" -ne 1 ]; then
      fail "CLAUDE.md contains $n_start relevio start marker(s) and $n_end end
       marker(s). Exactly one balanced pair is needed to know where the old
       block ends; with anything else, cutting it could delete your text.
       Nothing was changed in CLAUDE.md. Remove the leftover block by hand
       (everything from $MARK_START to $MARK_END), then re-run."
    fi
    l_start=$(grep -nF "$MARK_START" CLAUDE.md | cut -d: -f1)
    l_end=$(grep -nF "$MARK_END" CLAUDE.md | cut -d: -f1)
    if [ "$l_start" -ge "$l_end" ]; then
      fail "in CLAUDE.md the relevio end marker (line $l_end) comes before the
       start marker (line $l_start). Nothing was changed in CLAUDE.md. Fix the
       order by hand, then re-run."
    fi
    awk -v s="$MARK_START" -v e="$MARK_END" \
      'index($0,s){skip=1} !skip{print} index($0,e){skip=0}' CLAUDE.md > CLAUDE.md.tmp
    # If nothing but relevio's own scaffolding is left, the file IS relevio's
    # leftover (the installer created it in the first place) and an empty
    # "Instructions for agents" heading with no instructions under it would be
    # a lie. Anything the user wrote survives this test and keeps the file.
    # || true: under pipefail a grep matching no lines exits 1.
    LEFT="$(grep -v '^[[:space:]]*$' CLAUDE.md.tmp | grep -vx '# Instructions for agents' | wc -l)" || true
    if [ "$LEFT" -eq 0 ]; then
      rm CLAUDE.md CLAUDE.md.tmp
      info "removed: CLAUDE.md (it held nothing but relevio's old block; the
        methodology now lives in relevio's hooks and slash commands, and
        CLAUDE.md is yours to create if and when you want project instructions
        of your own)"
    else
      # The cut can leave a blank line where the block used to be. It is left
      # alone: those lines are now OUTSIDE anything relevio owns, and tidying
      # them would mean editing the user's file for cosmetics. This cannot
      # accumulate either, since the markers are gone after this single pass.
      mv CLAUDE.md.tmp CLAUDE.md
      info "updated: CLAUDE.md (relevio's old block removed; everything you
        wrote is untouched, and relevio will not write here again)"
    fi
  else
    info "NOTE: CLAUDE.md still holds relevio's pre-v0.18 block. Re-run with
        --update to remove it; until then the agent sees the rules twice."
  fi
fi

# --- 3b. Migration: drop the v0.18-0.19 relevio.md --------------------------
# Between v0.18 and v0.19 the methodology shipped as a relevio.md at the
# project root, injected at session start. Since v0.20 the hooks carry their
# messages themselves and no methodology file is installed; a leftover
# relevio.md would only mislead (an agent that reads it receives a second,
# stale set of rules, thresholds included). It is removed only when it is
# provably relevio's own file (its title line); a user file that happens to
# share the name is left alone, loudly.
if [ -f relevio.md ]; then
  if grep -qF 'Session methodology (relevio v' relevio.md; then
    if [ "$UPDATE" -eq 1 ]; then
      rm relevio.md
      info "removed: relevio.md (obsolete since v0.20: the hooks now carry the
        methodology themselves, so no file at the project root is needed)"
    else
      info "NOTE: relevio.md is from an older relevio (v0.18-0.19) and is now
        obsolete. Re-run with --update to remove it."
    fi
  else
    info "NOTE: a relevio.md exists at the project root but it is NOT relevio's
        file (its title line does not match), so it was left alone. Since
        v0.20 relevio installs no such file; if it is yours, consider renaming
        it so nobody mistakes it for relevio's."
  fi
fi

# --- 4. Handoff folder + library index --------------------------------------
mkdir -p docs/handoff
touch docs/handoff/.gitkeep
if [ -f docs/handoff/INDEX.md ]; then
  info "unchanged: docs/handoff/INDEX.md (never overwritten: it holds your history)"
else
  cp "$TPL/INDEX.md" docs/handoff/INDEX.md
  info "installed: docs/handoff/INDEX.md"
fi

# --- 5. Private mode (optional): keep the methodology out of the repo -------
# CLAUDE.md is deliberately NOT listed: it is yours, and whether it belongs in
# the repo is your call, not relevio's.
if [ "$PRIVATE" -eq 1 ]; then
  if [ -f .gitignore ] && grep -qF "$GI_START" .gitignore; then
    info "unchanged: .gitignore (private-mode block already present)"
  else
    { [ -f .gitignore ] && [ -s .gitignore ] && echo; cat <<EOF
$GI_START
.claude/
docs/handoff/
$GI_END
EOF
    } >> .gitignore
    info "updated: .gitignore (private mode: .claude/ and docs/handoff/ ignored)"
  fi
  TRACKED="$(git ls-files .claude docs/handoff 2>/dev/null | head -1 || true)"
  [ -n "$TRACKED" ] && info "NOTE: some of these files are already tracked by git; .gitignore does
        not untrack them. To untrack (keeping them on disk):
        git rm -r --cached .claude docs/handoff"
fi

# --- Done -------------------------------------------------------------------
cat <<'EOF'

Done. Next steps:

  1. The hooks load when a session STARTS: restart Claude Code (or open a new
     session) in this project.
  2. Per dev, once:
       - claude update            (old versions do not support the hooks)
       - /statusline              (see your own context % as the human)
       - window auto-detected per model (1M current, 200k Haiku) for the
         percentage; an unrecognized model gets a raw token count every 100k
         instead. Force percentage with "env": {"CLAUDE_CONTEXT_LIMIT": "..."}
       - custom warning thresholds? "CLAUDE_CONTEXT_WARN": "60,75"
  3. Team mode (default): commit .claude/settings.json, .claude/commands/,
     .claude/hooks/ and docs/handoff/ so every dev's agent follows the same
     rules and shares the session history. Solo/private mode: re-run with
     --private to gitignore all of it instead.
  4. The hooks and slash commands are relevio's files and --update replaces
     them whole: put your own project instructions in CLAUDE.md, which relevio
     never touches. The exact messages relevio sends the agent are readable in
     .claude/hooks/*.sh (and documented in the README).

Daily cycle: start every session with /kickoff, close it with /handoff (the
agent will also do it on its own when the context hook warns). The first
session has no handoff yet: just start working.
EOF
