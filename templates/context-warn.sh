#!/bin/bash
# claude-baton: context warning for the agent (sessions methodology in CLAUDE.md).
# The model is blind to its own window %: this hook un-blinds it by reading the
# usage from the transcript and injecting a notice via additionalContext
# (PostToolUse). Each band warns ONCE per session.
#
# Bands: soft/hard close-out thresholds (default 70,80; CLAUDE_CONTEXT_WARN)
# plus fixed revisit guards at 85, 90, 95 and 99% for reopened sessions.
# At 99% the STOP LAW applies: the agent must stop and ask before continuing.
#
# Config (via env, e.g. "env" in .claude/settings.local.json):
#   CLAUDE_CONTEXT_LIMIT  window size in tokens (default 200000; 1M users: 1000000)
#   CLAUDE_CONTEXT_WARN   "soft,hard" percentages (default "70,80")
#
# Portable: Linux and macOS (no tac, no GNU-only flags). Requires jq.
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION=$(echo "$INPUT" | jq -r '.session_id // "nosession"')
{ [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; } && exit 0

LIMIT="${CLAUDE_CONTEXT_LIMIT:-200000}"
WARN="${CLAUDE_CONTEXT_WARN:-70,80}"

emit() {
  jq -n --arg msg "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$msg}}'
}
once() {
  local mark="/tmp/claude-ctx-warn-${SESSION}-$1"
  [ -f "$mark" ] && return 1
  touch "$mark"
}

SOFT="${WARN%%,*}"
HARD="${WARN##*,}"
if ! [[ "$SOFT" =~ ^[0-9]+$ && "$HARD" =~ ^[0-9]+$ ]] || [ "$SOFT" -ge "$HARD" ]; then
  # Loud, but once: a misconfigured hook must not fake-work silently.
  once config && emit "claude-baton: CLAUDE_CONTEXT_WARN is invalid (\"$WARN\"). Expected two increasing percentages like \"70,80\". Context warnings are DISABLED until it is fixed; tell the user."
  exit 0
fi

# Last real usage entry. grep streams the file and works on both GNU and BSD.
USED=$(grep '"input_tokens"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '
  .message.usage as $u |
  ($u.input_tokens // 0) +
  ($u.cache_read_input_tokens // 0) +
  ($u.cache_creation_input_tokens // 0)' 2>/dev/null)
[[ "$USED" =~ ^[0-9]+$ ]] || exit 0
[ "$USED" -eq 0 ] && exit 0
PCT=$(( USED * 100 / LIMIT ))

# Mark every band crossed; speak only the highest one not yet emitted.
NAMES=(soft hard g85 g90 g95 g99)
LEVELS=("$SOFT" "$HARD" 85 90 95 99)
TOP=""
for i in "${!NAMES[@]}"; do
  [ "$PCT" -ge "${LEVELS[$i]}" ] || continue
  once "${NAMES[$i]}" && TOP="${NAMES[$i]}"
done
[ -z "$TOP" ] && exit 0

case "$TOP" in
  soft) emit "CONTEXT WARNING: ${PCT}% of the window used (${USED}/${LIMIT} tokens, soft threshold ${SOFT}%). Start closing the session: do NOT start new large tasks; finish what is open, write the handoff, and commit and push. The goal is to close leaving 10-15% of the window free so this conversation stays reopenable with full context." ;;
  hard) emit "CONTEXT WARNING: ${PCT}% of the window used (${USED}/${LIMIT} tokens, hard threshold ${HARD}%). CRITICAL: write the handoff NOW (CLAUDE.md convention, docs/handoff/, update INDEX.md), commit and push the verified work, and tell the user to rename this session (/rename DD-MM-YY short-title) and open a new one that starts with /kickoff." ;;
  g85)  emit "CONTEXT GUARD: ${PCT}% of the window used. If this is a REOPENED session (its handoff already written), keep answers short and do no new work: auto-compact is getting close. If this session has NO handoff yet, write it immediately." ;;
  g90)  emit "CONTEXT GUARD: ${PCT}% of the window used. Auto-compact is near. Answer briefly, avoid reading files or starting anything new, and remind the user in your reply that this conversation is almost full." ;;
  g95)  emit "CONTEXT GUARD: ${PCT}% of the window used. CRITICAL: from now on give only short answers, and warn the user in EVERY reply that auto-compact is imminent." ;;
  g99)  emit "STOP LAW (claude-baton, CLAUDE.md): ${PCT}% of the context window is used. Do NOT answer the user's pending request. Reply ONLY, in the user's language, that you reached 99% of context, that continuing will trigger auto-compact and destroy this conversation's remaining detail, and ask if they are SURE they want to continue. Then wait for their explicit confirmation." ;;
esac
exit 0
