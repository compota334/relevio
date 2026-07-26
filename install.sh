#!/usr/bin/env bash
# relevio installer
# Installs the working methodology for Claude Code into the CURRENT directory
# (your project root).
set -euo pipefail

VERSION="0.15.1"
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
  curl -fsSL ${REPO_RAW}/install.sh | bash -s -- --update
  bash /path/to/relevio/install.sh [--update|--force] [--private]

Options:
  --update   Upgrade an existing install to this version: refreshes the hook,
             the slash commands, and the block between the relevio markers in
             CLAUDE.md. This is what you want to move from an older relevio to
             this one. All safety checks stay ON. Anything you wrote OUTSIDE
             the markers is never touched.
  --force    Everything --update does, PLUS it overrides the safety check that
             stops the install when your CLAUDE.md already describes a session
             methodology of its own. Use only when you know that check is a
             false positive. Neither flag ever touches docs/handoff/ or
             INDEX.md.
  --private  Also add CLAUDE.md, .claude/ and docs/handoff/ to .gitignore
             (solo mode: the methodology stays local, out of the repo).
             Without it, the files are left for you to commit (team mode).
  --help     This text.

WARNING about the markers: everything BETWEEN $MARK_START and
$MARK_END belongs to relevio and is REPLACED on --update/--force.
Keep your own instructions outside that block; they are then never touched.

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
command -v jq >/dev/null 2>&1 || fail "jq is required (the context hook parses transcripts with it).
       Install it first: sudo apt install jq   |   brew install jq"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "this directory is not a git repository.
       The methodology relies on commits, pushes and handoff history.
       cd into your project, or run 'git init' first."

# An existing CLAUDE.md is never overwritten: the section is APPENDED, so your
# own instructions always survive. But appending on top of a session
# methodology someone already wrote BY HAND leaves the agent with two
# conflicting sets of rules (two handoff naming schemes, two cycles), and the
# agent cannot tell which one wins. Detect that here, before anything is
# written, so the human resolves it instead of discovering it later.
if [ "$FORCE" -ne 1 ] && [ -f CLAUDE.md ] && ! grep -qF "$MARK_START" CLAUDE.md \
   && grep -qEi 'docs/handoff|/kickoff|/handoff' CLAUDE.md; then
  fail "CLAUDE.md already describes a session/handoff methodology, and it is not
       wrapped in relevio markers, so relevio cannot tell which part is its own.
       Appending would leave your agent with TWO conflicting sets of rules.
       Nothing has been installed.

       Do NOT wrap your own text in the relevio markers to protect it: the
       block BETWEEN those markers is exactly what --update and --force
       REPLACE. Putting your methodology there would get it overwritten the
       next time you upgrade. Your text is safe anywhere OUTSIDE the markers.

       Pick one:

       (a) KEEP YOURS as the source of truth: leave your methodology where it
           is and do NOT install relevio's CLAUDE.md section at all. Install
           only the hook and the slash commands, by copying them yourself:
             mkdir -p .claude/hooks .claude/commands
             cp <relevio>/templates/context-warn.sh .claude/hooks/
             cp <relevio>/templates/{kickoff,handoff,revisit}.md .claude/commands/
           then register the hook in .claude/settings.json. Adapt your own
           section by hand when you want relevio's newer ideas.

       (b) REPLACE yours with relevio's: delete your methodology section from
           CLAUDE.md, then re-run. relevio's section arrives between the
           markers, and from then on --update refreshes just that block while
           everything you write outside it stays untouched.

       (c) FALSE POSITIVE (your CLAUDE.md mentions handoffs for unrelated
           reasons): re-run with --force to append anyway."
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
for stamped in context-warn.sh CLAUDE.md.section; do
  grep -qF "relevio v${VERSION}" "$TPL/$stamped" \
    || fail "template $stamped is not stamped 'relevio v${VERSION}'.
       This installer and its templates come from different versions, so the
       version recorded in your project would be wrong. Nothing was installed.
       Re-download a matching pair (installer + templates) and try again."
done
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
       made to THIS file will be lost; your CLAUDE.md text outside the relevio
       markers is not affected)."
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
  if [ "$UPDATE" -eq 1 ]; then
    # Everything between the markers is relevio's and gets REPLACED; everything
    # outside them is the user's and is copied through untouched.
    # Trailing blank lines are dropped before the separator is appended below.
    # Without that the run is not idempotent: the blank line this run emits as a
    # separator survives the next run's strip (it sits BEFORE the start marker),
    # which then adds one of its own, so the block would drift one line further
    # down on every single re-run and CLAUDE.md would never show a clean diff.
    awk -v s="$MARK_START" -v e="$MARK_END" '
      index($0,s){skip=1}
      !skip{ line[++n]=$0; if (NF) last=n }
      index($0,e){skip=0}
      END{ for (i=1; i<=last; i++) print line[i] }' CLAUDE.md > CLAUDE.md.tmp
    { echo; cat "$TPL/CLAUDE.md.section"; } >> CLAUDE.md.tmp
    mv CLAUDE.md.tmp CLAUDE.md
    info "updated: CLAUDE.md (the block between the relevio markers was REPLACED
        with v${VERSION}; everything outside the markers was left untouched, and
        the new block now sits at the end of the file)"
  else
    info "unchanged: CLAUDE.md (relevio section already present; --update refreshes it)"
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
       - window auto-detected per model (1M current, 200k Haiku) for the
         percentage; an unrecognized model gets a raw token count every 100k
         instead. Force percentage with "env": {"CLAUDE_CONTEXT_LIMIT": "..."}
       - custom warning thresholds? "CLAUDE_CONTEXT_WARN": "60,75"
  3. Team mode (default): commit CLAUDE.md, .claude/settings.json,
     .claude/commands/, .claude/hooks/ and docs/handoff/ so every dev's agent
     follows the same rules and shares the session history. Solo/private mode:
     re-run with --private to gitignore all of it instead.

Daily cycle: start every session with /kickoff, close it with /handoff (the
agent will also do it on its own when the context hook warns). The first
session has no handoff yet: just start working.
EOF
