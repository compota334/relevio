#!/bin/bash
# relevio: inject the session methodology at session start (plugin mode).
# Plugins cannot ship an auto-loaded CLAUDE.md, so this hook arms the agent
# with the relevio cycle on EVERY session, kickoff or not. The message depends
# on why the session started (the "source" field of the SessionStart input):
#   startup|clear  -> methodology summary
#   resume         -> revisited-session rules (ask, don't work)
#   compact        -> auto-compact just destroyed detail; salvage what remains
# Subagents are untouched: SessionStart fires for the main session only
# (subagent spawns emit SubagentStart, which this plugin does not hook), and
# the messages carry a defensive line anyway. Requires jq.
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

emit() {
  jq -n --arg msg "$1" \
    '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$msg}}'
}

SUBAGENT_LINE="If you are a SUBAGENT (spawned via the Task tool), ignore this methodology entirely and simply return your result."

case "$SOURCE" in
  resume)
    emit "relevio: this is a REOPENED conversation, part of the session archive. It is for ASKING, not for working: it sits near the top of its context window, and auto-compact would destroy the detail that makes it valuable. Answer briefly, avoid reading files or starting new work, and send new work to a fresh session opened with /relevio:kickoff. Context guards fire at 85, 90, 95 and 99%; at 99% the STOP LAW applies: do not answer the pending request, warn the user (in their language) that one more exchange may trigger auto-compact, and wait for their explicit confirmation. $SUBAGENT_LINE" ;;
  compact)
    emit "relevio: auto-compact JUST HAPPENED in this conversation: the fine-grained detail before this point has been summarized away. Tell the user. If this session has no handoff written yet, write it NOW (docs/handoff/, append the INDEX.md row) with whatever detail remains, then recommend closing this session and opening a fresh one with /relevio:kickoff. $SUBAGENT_LINE" ;;
  *)
    emit "relevio session methodology (auto-injected at session start): this project follows the relevio cycle. (1) Sessions open with /relevio:kickoff, which reads docs/handoff/INDEX.md and the latest handoff before touching code; if the user skipped it and docs/handoff/ exists, suggest it. (2) A hook keeps you aware of your context window: informational checkpoints at 10-60% (no action needed; use them to pace the session: from around 50-60% prefer finishing what is open over starting the largest pending task), close-out warnings at 70 and 80%, guards at 85-99%. (3) Write the handoff ONLY when the close-out warning arrives or the user asks: a finished phase with window still available is a reason to keep working, not to close. (4) Sessions close with /relevio:handoff, then the user renames the conversation and opens a fresh one. $SUBAGENT_LINE" ;;
esac
exit 0
