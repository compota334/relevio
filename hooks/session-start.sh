#!/bin/bash
# relevio v0.20.1
# relevio: inject the session cycle at session start.
#
# relevio does NOT write to your CLAUDE.md. The methodology reaches the agent
# through this hook and through the slash commands; CLAUDE.md is yours alone:
# relevio never reads it, never edits it, never depends on it.
#
# The message depends on why the session started (the "source" field of the
# SessionStart input):
#   startup|clear  -> the operational core of the cycle (see below)
#   resume         -> revisited-session rules only. A reopened conversation
#                     starts near the TOP of its window, so the cycle rules
#                     would spend the little room it has left on things it is
#                     not going to do: a revisited session asks, it does not
#                     work.
#   compact        -> auto-compact just destroyed detail; salvage what remains
#
# DESIGN RULE: the core says NOTHING about closing, handoffs or close-out
# thresholds. An agent that learns the close-out rules at minute zero starts
# anticipating them long before they apply (observed in real sessions: agents
# "wrapping up" at 60% because they knew a warning existed at 70%). Every
# instruction travels WITH the event that triggers it: the PostToolUse hook
# (context-warn.sh) carries the full close-out instructions inside the very
# message that asks for the close-out, and the /relevio:kickoff and /relevio:handoff commands
# carry their own step-by-step rituals. Nothing here may pre-announce any of
# it, negations included ("this is not X" still plants X).
#
# The core DOES announce the checkpoint cadence (every 10%): that is the one
# number that reduces anxiety instead of feeding it, because it turns silence
# into information (no new report = the next 10% mark is not crossed yet).
# Without it, agents fill the silence by guessing they are near the limit
# (observed: an agent at 30% recommending closure "to be safe"). The close-out
# thresholds stay unannounced: cadence tells the agent where it stands, never
# when the session ends.
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

# KEEP EVERY EMITTED MESSAGE WELL UNDER 8000 CHARACTERS. Claude Code caps how
# much a hook may inject: past the cap the agent receives a ~2 KB preview plus
# a file path, with no visible error (measured 2026-07 on Claude Code 2.1.207:
# ~8 KB arrives intact, ~12 KB does not). tests/install.sh asserts the size.
case "$SOURCE" in
  resume)
    emit "relevio: this is a REOPENED conversation, part of the session archive. Its purpose is answering questions about what happened here, not doing new work: it sits near the top of its context window, and auto-compact would destroy the detail that makes it valuable. Keep answers brief, avoid reading files or starting tasks that consume significant context, and if the user wants new work done, suggest opening a fresh session with /relevio:kickoff. $SUBAGENT_LINE"
    ;;
  compact)
    emit "relevio: auto-compact just happened in this conversation: the fine-grained detail before this point has been summarized away. Tell the user. If no handoff has been written for this session yet, write one now (docs/handoff/YYYY-MM-DD_<short-title>.md, append a row to docs/handoff/INDEX.md) with whatever detail remains, then recommend closing this session and opening a fresh one with /relevio:kickoff. $SUBAGENT_LINE"
    ;;
  *)
    emit "relevio v0.20.1: this project uses the relevio session cycle, a structured way to carry work and context from one coding session to the next, so that nothing is lost between them.

OPEN: sessions start with /relevio:kickoff, which reads docs/handoff/INDEX.md and the LATEST handoff before any code (it may live on another branch) and settles with the user which branch to work on. If the user skipped /relevio:kickoff and docs/handoff/ exists, suggest it.

DURING THE SESSION: a PostToolUse hook tracks your context-window usage and reports it to you; you cannot see your own usage without it. It posts a status update roughly every 10% of the window. That cadence is information you can use: silence means you have NOT crossed the next 10% mark, so never guess or assume your usage is higher than the last number you received. Most of its messages are plain status updates that need no response and no change in behavior: just a number so you know where you stand. When the hook needs you to do something, the message itself will say so clearly and carry complete instructions. Until such a message arrives, the window needs nothing from you and is never a reason to change course: let the user's request, not the window, decide what you do and when you are done.

$SUBAGENT_LINE"
    ;;
esac
exit 0
