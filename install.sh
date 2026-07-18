#!/usr/bin/env bash
# relevio installer
# Installs the working methodology for Claude Code into the CURRENT directory
# (your project root).
set -euo pipefail

VERSION="0.4.0"
REPO_RAW="https://raw.githubusercontent.com/compota334/relevio/main"
TEMPLATES=(context-warn.sh handoff.md kickoff.md revisit.md CLAUDE.md.section INDEX.md)
MARK_START="<!-- relevio:start -->"
MARK_END="<!-- relevio:end -->"
GI_START="# >>> relevio private mode >>>"
GI_END="# <<< relevio private mode <<<"

usage() {
  cat <<EOF
relevio v${VERSION} installer

Usage (from YOUR project root, which must be a git repository):
  curl -fsSL ${REPO_RAW}/install.sh | bash
  curl -fsSL ${REPO_RAW}/install.sh | bash -s -- --force --private
  bash /path/to/relevio/install.sh [--force] [--private]

Options:
  --force    Overwrite installed files you have edited locally (refuses
             otherwise). Never touches docs/handoff/ content or INDEX.md.
  --private  Also add CLAUDE.md, .claude/ and docs/handoff/ to .gitignore
             (solo mode: the methodology stays local, out of the repo).
             Without it, the files are left for you to commit (team mode).
  --help     This text.

Uninstall:
  curl -fsSL ${REPO_RAW}/uninstall.sh | bash
EOF
}

FORCE=0
PRIVATE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
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
command -v jq >/dev/null 2>&1 || fail "jq is required (the context hook parses transcripts with it).
       Install it first: sudo apt install jq   |   brew install jq"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "this directory is not a git repository.
       The methodology relies on commits, pushes and handoff history.
       cd into your project, or run 'git init' first."

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
echo

# --- Helper: copy a template, refusing to clobber local edits ---------------
install_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    info "unchanged: $dest"
    return 0
  fi
  if [ -f "$dest" ] && [ "$FORCE" -ne 1 ]; then
    fail "$dest already exists and differs from the template.
       Re-run with --force to overwrite it (your local edits will be lost)."
  fi
  cp "$src" "$dest"
  chmod "$mode" "$dest"
  info "installed: $dest"
}

# --- 1. Hook + slash commands -----------------------------------------------
mkdir -p .claude/hooks .claude/commands
install_file "$TPL/context-warn.sh" .claude/hooks/context-warn.sh 755
install_file "$TPL/handoff.md" .claude/commands/handoff.md 644
install_file "$TPL/kickoff.md" .claude/commands/kickoff.md 644
install_file "$TPL/revisit.md" .claude/commands/revisit.md 644

# --- 2. Register the hook in .claude/settings.json (merge, don't clobber) ---
SETTINGS=".claude/settings.json"
HOOK_ENTRY='{"matcher":"*","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/context-warn.sh"}]}'
if [ ! -f "$SETTINGS" ]; then
  jq -n --argjson e "$HOOK_ENTRY" '{"hooks":{"PostToolUse":[$e]}}' > "$SETTINGS"
  info "installed: $SETTINGS"
elif jq -e '.hooks.PostToolUse[]?.hooks[]?.command // empty | select(contains("context-warn.sh"))' \
       "$SETTINGS" >/dev/null 2>&1; then
  info "unchanged: $SETTINGS (hook already registered)"
else
  jq -e . "$SETTINGS" >/dev/null 2>&1 || fail "$SETTINGS exists but is not valid JSON. Fix it, then re-run."
  TMP="$(mktemp)"
  jq --argjson e "$HOOK_ENTRY" \
     '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [$e])' \
     "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
  info "updated: $SETTINGS (hook registered, existing settings preserved)"
fi

# --- 3. CLAUDE.md methodology section (marker-delimited, idempotent) --------
if [ ! -f CLAUDE.md ]; then
  { echo "# Instructions for agents"; echo; cat "$TPL/CLAUDE.md.section"; } > CLAUDE.md
  info "installed: CLAUDE.md"
elif grep -qF "$MARK_START" CLAUDE.md; then
  if [ "$FORCE" -eq 1 ]; then
    awk -v s="$MARK_START" -v e="$MARK_END" \
      'index($0,s){skip=1} !skip{print} index($0,e){skip=0}' CLAUDE.md > CLAUDE.md.tmp
    { echo; cat "$TPL/CLAUDE.md.section"; } >> CLAUDE.md.tmp
    mv CLAUDE.md.tmp CLAUDE.md
    info "updated: CLAUDE.md (relevio section refreshed, moved to the end)"
  else
    info "unchanged: CLAUDE.md (relevio section already present; --force refreshes it)"
  fi
else
  { echo; cat "$TPL/CLAUDE.md.section"; } >> CLAUDE.md
  info "updated: CLAUDE.md (relevio section appended)"
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
if [ "$PRIVATE" -eq 1 ]; then
  if [ -f .gitignore ] && grep -qF "$GI_START" .gitignore; then
    info "unchanged: .gitignore (private-mode block already present)"
  else
    { [ -f .gitignore ] && [ -s .gitignore ] && echo; cat <<EOF
$GI_START
CLAUDE.md
.claude/
docs/handoff/
$GI_END
EOF
    } >> .gitignore
    info "updated: .gitignore (private mode: CLAUDE.md, .claude/, docs/handoff/ ignored)"
  fi
  TRACKED="$(git ls-files CLAUDE.md .claude docs/handoff 2>/dev/null | head -1 || true)"
  [ -n "$TRACKED" ] && info "NOTE: some of these files are already tracked by git; .gitignore does
        not untrack them. To untrack (keeping them on disk):
        git rm -r --cached CLAUDE.md .claude docs/handoff"
fi

# --- Done -------------------------------------------------------------------
cat <<'EOF'

Done. Next steps:

  1. The hook loads when a session STARTS: restart Claude Code (or open a new
     session) in this project.
  2. Per dev, once:
       - claude update            (old versions do not support the hook)
       - /statusline              (see your own context % as the human)
       - 1M window? Add "env": {"CLAUDE_CONTEXT_LIMIT": "1000000"}
         to your .claude/settings.local.json
       - custom warning thresholds? "CLAUDE_CONTEXT_WARN": "60,75"
  3. Team mode (default): commit CLAUDE.md, .claude/settings.json,
     .claude/commands/, .claude/hooks/ and docs/handoff/ so every dev's agent
     follows the same rules and shares the session history. Solo/private mode:
     re-run with --private to gitignore all of it instead.

Daily cycle: start every session with /kickoff, close it with /handoff (the
agent will also do it on its own when the context hook warns). The first
session has no handoff yet: just start working.
EOF
