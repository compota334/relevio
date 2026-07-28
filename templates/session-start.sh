#!/bin/bash
# relevio v0.18.0
# relevio: inject the session methodology at session start.
#
# relevio does NOT write to your CLAUDE.md. The methodology lives in its own
# file, relevio.md, and reaches the agent through this hook. CLAUDE.md is
# yours alone: relevio never reads it, never edits it, never depends on it.
#
# The message depends on why the session started (the "source" field of the
# SessionStart input):
#   startup|clear  -> the full methodology (relevio.md)
#   resume         -> revisited-session rules only. A reopened conversation
#                     starts near the TOP of its window, so dumping the whole
#                     file into it would spend the little room it has left on
#                     rules it does not need: a revisited session asks, it does
#                     not work.
#   compact        -> auto-compact just destroyed detail; salvage what remains
#
# Subagents are untouched: SessionStart fires for the main session only
# (subagent spawns emit SubagentStart, which relevio does not hook), and the
# messages carry a defensive line anyway. Requires jq.
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

emit() {
  jq -n --arg msg "$1" \
    '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$msg}}'
}

SUBAGENT_LINE="If you are a SUBAGENT (spawned via the Task tool), ignore this methodology entirely and simply return your result."

case "$SOURCE" in
  resume)
    emit "relevio: this is a REOPENED conversation, part of the session archive. It is for ASKING, not for working: it sits near the top of its context window, and auto-compact would destroy the detail that makes it valuable. Answer briefly, avoid reading files or starting new work, and send new work to a fresh session opened with /kickoff. Context guards fire at 85, 90, 95 and 99%; at 99% the STOP LAW applies: do not answer the pending request, warn the user (in their language) that one more exchange may trigger auto-compact, and wait for their explicit confirmation. $SUBAGENT_LINE"
    exit 0 ;;
  compact)
    emit "relevio: auto-compact JUST HAPPENED in this conversation: the fine-grained detail before this point has been summarized away. Tell the user. If this session has no handoff written yet, write it NOW (docs/handoff/, append the INDEX.md row) with whatever detail remains, then recommend closing this session and opening a fresh one with /kickoff. $SUBAGENT_LINE"
    exit 0 ;;
esac

# --- startup | clear: inject the methodology itself -------------------------
# Everything below is about ONE failure: relevio.md not being readable. It is
# the only way this design can break, and it must never break quietly. Without
# this file the agent simply has no methodology, and nothing else in the
# session would hint at it: no handoff gets written, no kickoff ritual runs,
# and the session dies at auto-compact exactly like it did before relevio.
# So: say it loudly, to the agent, with the fix.
if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  emit "relevio ERROR: the session-start hook ran without CLAUDE_PROJECT_DIR set, so it cannot locate relevio.md and the session methodology was NOT loaded. Tell the user: relevio is installed but inert in this session. It is likely registered with a hand-edited command in .claude/settings.json; re-running the installer restores the correct entry."
  exit 0
fi
METHODOLOGY="$CLAUDE_PROJECT_DIR/relevio.md"
if [ ! -r "$METHODOLOGY" ]; then
  emit "relevio ERROR: $METHODOLOGY is missing or unreadable, so the session methodology was NOT loaded. relevio is registered as a hook but has nothing to inject: no kickoff ritual, no context close-out rules, no handoff. Tell the user, and do not pretend the methodology is active. Fix: restore relevio.md (it is committed with the project in team mode) or re-run the installer from the project root."
  exit 0
fi
BODY=$(cat "$METHODOLOGY")
if [ -z "$BODY" ]; then
  emit "relevio ERROR: $METHODOLOGY exists but is EMPTY, so the session methodology was NOT loaded. Tell the user, and do not pretend the methodology is active. Fix: restore the file from the repo, or re-run the installer from the project root."
  exit 0
fi

emit "relevio session methodology (auto-injected at session start from relevio.md; it governs how sessions open, are paced and close, and nothing else: how this project codes and verifies is in CLAUDE.md). Sessions open with /kickoff and close with /handoff. $SUBAGENT_LINE

$BODY"
exit 0
