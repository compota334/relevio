#!/bin/bash
# relevio v0.18.0
# relevio: inject the session methodology at session start (plugin mode).
#
# Same job as templates/session-start.sh (the script-installer version), with
# two differences forced by how plugins work:
#   - the methodology is read from the PLUGIN, not from the project. A plugin
#     installs no files into the user's repo, so there is no relevio.md there;
#     the single source of truth is templates/relevio.md inside the plugin,
#     which is also what the installer ships. One text, two delivery paths.
#   - the slash commands are namespaced (/relevio:kickoff), and the hooks live
#     in the plugin instead of .claude/hooks/. relevio.md is written for the
#     installer layout, so the prefix below corrects both points instead of
#     duplicating the whole file just to change a handful of paths.
#
# The message depends on why the session started (the "source" field of the
# SessionStart input):
#   startup|clear  -> the full methodology
#   resume         -> revisited-session rules only. A reopened conversation
#                     starts near the TOP of its window, so dumping the whole
#                     file into it would spend the little room it has left on
#                     rules it does not need: a revisited session asks, it does
#                     not work.
#   compact        -> auto-compact just destroyed detail; salvage what remains
#
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
    emit "relevio: this is a REOPENED conversation, part of the session archive. It is for ASKING, not for working: it sits near the top of its context window, and auto-compact would destroy the detail that makes it valuable. Answer briefly, avoid reading files or starting new work, and send new work to a fresh session opened with /relevio:kickoff. Context guards fire at 85, 90, 95 and 99%; at 99% the STOP LAW applies: do not answer the pending request, warn the user (in their language) that one more exchange may trigger auto-compact, and wait for their explicit confirmation. $SUBAGENT_LINE"
    exit 0 ;;
  compact)
    emit "relevio: auto-compact JUST HAPPENED in this conversation: the fine-grained detail before this point has been summarized away. Tell the user. If this session has no handoff written yet, write it NOW (docs/handoff/, append the INDEX.md row) with whatever detail remains, then recommend closing this session and opening a fresh one with /relevio:kickoff. $SUBAGENT_LINE"
    exit 0 ;;
esac

# --- startup | clear: inject the methodology itself -------------------------
# A plugin whose methodology file cannot be read is a plugin that does nothing,
# silently: no kickoff ritual, no close-out rules, no handoff, and not one
# symptom the user could notice. Say it loudly instead.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  emit "relevio ERROR: the session-start hook ran without CLAUDE_PLUGIN_ROOT set, so it cannot locate the methodology and NOTHING was loaded. Tell the user: the relevio plugin is enabled but inert in this session, and reinstalling it from its marketplace should restore it."
  exit 0
fi
METHODOLOGY="$CLAUDE_PLUGIN_ROOT/templates/relevio.md"
if [ ! -r "$METHODOLOGY" ]; then
  emit "relevio ERROR: $METHODOLOGY is missing or unreadable, so the session methodology was NOT loaded. The relevio plugin is enabled but has nothing to inject. Tell the user, and do not pretend the methodology is active: reinstalling the plugin from its marketplace should restore it."
  exit 0
fi
BODY=$(cat "$METHODOLOGY")
if [ -z "$BODY" ]; then
  emit "relevio ERROR: $METHODOLOGY exists but is EMPTY, so the session methodology was NOT loaded. Tell the user, and do not pretend the methodology is active: reinstalling the plugin from its marketplace should restore it."
  exit 0
fi

emit "relevio session methodology (auto-injected at session start). It governs how sessions open, are paced against the context window and close, and nothing else: how this project codes and verifies is its own business, in its CLAUDE.md, which relevio never touches.

READ THIS FIRST, it overrides the text below on two points, because relevio is running here as a PLUGIN rather than a per-project install: (1) the slash commands are NAMESPACED, so wherever the text says /kickoff, /handoff or /revisit, use /relevio:kickoff, /relevio:handoff and /relevio:revisit; (2) the hooks and this methodology live inside the plugin, so there is no relevio.md and no .claude/hooks/ in this project, and any path the text gives for them does not apply. Everything else reads as written. $SUBAGENT_LINE

$BODY"
exit 0
