#!/usr/bin/env bash
# relevio uninstaller
# Removes everything install.sh added to the CURRENT directory, EXCEPT
# docs/handoff/ (your history) which is always kept.
#
# Usage (from your project root):
#   curl -fsSL https://raw.githubusercontent.com/compota334/relevio/main/uninstall.sh | bash
#   bash /path/to/relevio/uninstall.sh
set -euo pipefail

MARK_START="<!-- relevio:start -->"
MARK_END="<!-- relevio:end -->"
GI_START="# >>> relevio private mode >>>"
GI_END="# <<< relevio private mode <<<"

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

echo "relevio uninstaller"
echo "Target project: $(pwd)"
echo

# --- 1. Hook + slash commands -----------------------------------------------
for f in .claude/hooks/context-warn.sh .claude/commands/handoff.md .claude/commands/kickoff.md .claude/commands/revisit.md; do
  if [ -f "$f" ]; then rm "$f"; info "removed: $f"; fi
done
rmdir .claude/hooks .claude/commands 2>/dev/null || true

# --- 2. Hook registration in .claude/settings.json --------------------------
SETTINGS=".claude/settings.json"
if [ -f "$SETTINGS" ]; then
  command -v jq >/dev/null 2>&1 || fail "jq is required to clean $SETTINGS. Install it, or edit the file by hand."
  jq -e . "$SETTINGS" >/dev/null 2>&1 || fail "$SETTINGS is not valid JSON. Clean it by hand: remove the PostToolUse entry that references context-warn.sh."
  TMP="$(mktemp)"
  jq '
    if .hooks.PostToolUse then
      .hooks.PostToolUse = [ .hooks.PostToolUse[]
        | select(((.hooks // []) | map(.command // "") | any(contains("context-warn.sh"))) | not) ]
    else . end
    | if .hooks.PostToolUse == [] then del(.hooks.PostToolUse) else . end
    | if .hooks == {} then del(.hooks) else . end
  ' "$SETTINGS" > "$TMP"
  if [ "$(cat "$TMP")" = "{}" ]; then
    rm "$SETTINGS" "$TMP"
    info "removed: $SETTINGS (nothing left in it)"
  elif cmp -s "$TMP" "$SETTINGS"; then
    rm "$TMP"
    info "unchanged: $SETTINGS (no context-warn hook registered)"
  else
    mv "$TMP" "$SETTINGS"
    info "updated: $SETTINGS (context-warn hook unregistered, rest preserved)"
  fi
fi
rmdir .claude 2>/dev/null || true

# --- 3. CLAUDE.md section ----------------------------------------------------
if [ -f CLAUDE.md ] && grep -qF "$MARK_START" CLAUDE.md; then
  awk -v s="$MARK_START" -v e="$MARK_END" \
    'index($0,s){skip=1} !skip{print} index($0,e){skip=0}' CLAUDE.md > CLAUDE.md.tmp
  # || true: under pipefail, a grep with no surviving lines exits 1 and would
  # kill the script right when CLAUDE.md contains nothing but our section.
  LEFT="$(grep -v '^[[:space:]]*$' CLAUDE.md.tmp | grep -vx '# Instructions for agents' | wc -l)" || true
  if [ "$LEFT" -eq 0 ]; then
    rm CLAUDE.md CLAUDE.md.tmp
    info "removed: CLAUDE.md (it only contained the relevio section)"
  else
    mv CLAUDE.md.tmp CLAUDE.md
    info "updated: CLAUDE.md (relevio section removed, your content kept)"
  fi
else
  info "unchanged: CLAUDE.md (no relevio section found)"
fi

# --- 4. Private-mode block in .gitignore -------------------------------------
if [ -f .gitignore ] && grep -qF "$GI_START" .gitignore; then
  awk -v s="$GI_START" -v e="$GI_END" \
    'index($0,s){skip=1} !skip{print} index($0,e){skip=0}' .gitignore > .gitignore.tmp
  if [ -s .gitignore.tmp ]; then
    mv .gitignore.tmp .gitignore
    info "updated: .gitignore (private-mode block removed)"
  else
    rm .gitignore .gitignore.tmp
    info "removed: .gitignore (it only contained the private-mode block)"
  fi
fi

# --- Done --------------------------------------------------------------------
echo
echo "Done. docs/handoff/ was KEPT on purpose: it is your project's history."
echo "Delete it yourself only if you are sure you want to lose it."
