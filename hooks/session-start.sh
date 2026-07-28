#!/bin/bash
# relevio v0.18.0
# relevio: inject the session methodology at session start (plugin mode).
#
# Same job as templates/session-start.sh, with two differences forced by how
# plugins work: the methodology is read from the PLUGIN (a plugin installs no
# files into the user's repo, so there is no relevio.md there; the single
# source of truth is templates/relevio.md inside the plugin, which is also
# what the installer ships), and the slash commands are namespaced.
#
# The message depends on why the session started (the "source" field of the
# SessionStart input):
#   startup|clear  -> the operational core of the methodology (see below)
#   resume         -> revisited-session rules only. A reopened conversation
#                     starts near the TOP of its window, so the cycle rules
#                     would spend the little room it has left on things it is
#                     not going to do: a revisited session asks, it does not
#                     work.
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

CORE="relevio v0.18.0: this project runs the relevio session cycle. It governs sessions ONLY (how they open, are paced against the context window, and close). How this project codes, verifies and handles errors is in CLAUDE.md, which relevio never touches. Full text in templates/relevio.md inside the relevio plugin: read it when you need the detail.

OPEN: sessions start with /relevio:kickoff, which reads docs/handoff/INDEX.md and the LATEST handoff before any code (it may live on another branch) and settles with the user which branch to work on. If the user skipped it and docs/handoff/ exists, suggest it.

PACE: a PostToolUse hook reports your context usage; you cannot see it otherwise. Checkpoints at 10-60% need no action, but use them to pace: from 50-60% prefer finishing what is open over starting the largest pending task. At 70% HARVEST rather than brake: open no new work, and among what is already open finish first whatever depends on understanding you DERIVED (why an approach fails, what you already ruled out) rather than facts the next session can cheaply re-read; each item must fit complete, verification and commit included.

CLOSE: at 80%, or on the user's request, write the handoff NOW: docs/handoff/YYYY-MM-DD_<short-title>.md with what was done (commit hashes), lessons that cost real effort, pending work in order, and the REASONING behind anything left open; append a row to INDEX.md; commit and push. A finished phase with window left is a reason to keep working, not to close. Never stretch a session into auto-compact.

REVISIT: a reopened session is for ASKING, not working. Guards fire at 85/90/95%, and at 99% the STOP LAW applies: do not answer the pending request, tell the user auto-compact is imminent, and wait for explicit confirmation.

$SUBAGENT_LINE"

case "$SOURCE" in
  resume)
    emit "relevio: this is a REOPENED conversation, part of the session archive. It is for ASKING, not for working: it sits near the top of its context window, and auto-compact would destroy the detail that makes it valuable. Answer briefly, avoid reading files or starting new work, and send new work to a fresh session opened with /relevio:kickoff. Context guards fire at 85, 90, 95 and 99%; at 99% the STOP LAW applies: do not answer the pending request, warn the user (in their language) that one more exchange may trigger auto-compact, and wait for their explicit confirmation. $SUBAGENT_LINE"
    exit 0 ;;
  compact)
    emit "relevio: auto-compact JUST HAPPENED in this conversation: the fine-grained detail before this point has been summarized away. Tell the user. If this session has no handoff written yet, write it NOW (docs/handoff/, append the INDEX.md row) with whatever detail remains, then recommend closing this session and opening a fresh one with /relevio:kickoff. $SUBAGENT_LINE"
    exit 0 ;;
esac

# --- startup | clear: inject the operational core ---------------------------
# What follows is a COMPACT core, not the whole of relevio.md, and the reason
# is a hard limit rather than a preference. Claude Code caps how much a hook
# may inject: past the cap the agent receives only a ~2 KB preview plus the
# path of a file it would have to go and read. Measured on 2026-07 against
# Claude Code 2.1.207: ~8 KB arrives intact, ~12 KB does not, so the cutoff
# sits between them. Piping the full 11 KB methodology through here delivered
# its first sixth and dropped the close-out thresholds, the STOP LAW and the
# handoff structure: exactly the parts that matter, lost with no error anyone
# could see from inside the session. It was a poor trade on its own terms too,
# since every session paid 11 KB of window for rules it needs at two moments.
#
# So the split is: this core carries what the agent must know at ALL times,
# the plugin's templates/relevio.md holds the full text for when it needs the detail, and the
# /relevio:kickoff and /relevio:handoff commands carry their own step-by-step
# rituals (a slash
# command is read in full when invoked, so it has no such limit).
#
# KEEP THE EMITTED MESSAGE WELL UNDER 8000 CHARACTERS, error branches included.
# tests/install.sh asserts the size, because exceeding it fails silently.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  emit "relevio ERROR: the session-start hook ran without CLAUDE_PLUGIN_ROOT set, so it cannot find its methodology file. Tell the user: relevio is installed but cannot confirm its own methodology file is there. It is likely registered with a hand-edited command in .claude/settings.json; reinstalling the plugin from its marketplace should restore it."
  exit 0
fi
METHODOLOGY="$CLAUDE_PLUGIN_ROOT/templates/relevio.md"
if [ ! -r "$METHODOLOGY" ] || [ ! -s "$METHODOLOGY" ]; then
  emit "relevio ERROR: $METHODOLOGY is missing, unreadable or empty. The session cycle below still applies, but the full methodology it points to is NOT available, so /relevio:kickoff and /relevio:handoff will be working without their reference text. Tell the user rather than pretending everything is in place. Fix: reinstall the relevio plugin from its marketplace.

$CORE"
  exit 0
fi

emit "$CORE"
exit 0
