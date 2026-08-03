#!/bin/bash
# relevio v0.20.0
# relevio: context warning for the agent.
# The model is blind to its own window %: this hook un-blinds it by reading the
# usage from the transcript and injecting a notice via additionalContext
# (PostToolUse). Each band warns ONCE per session.
#
# DESIGN RULE (anti-anticipation): every instruction travels WITH the event
# that triggers it, never before. The checkpoints are a bare number with no
# talk of closing (a negation like "not a close signal" still plants the
# idea); the soft message steers toward finishing without asking for the
# handoff; the hard message carries the FULL close-out checklist, because it
# is the first time the agent needs it. An agent that learns the close-out
# early starts anticipating it (observed: sessions closing at 60% because
# they knew a warning existed at 70%).
#
# Two modes, chosen by whether the model's window size is known:
#
# PERCENTAGE mode (window size known -- see resolution below). Bands:
# informational checkpoints every 10% from 10 to 60%, soft/hard close-out
# thresholds (default 70,80; CLAUDE_CONTEXT_WARN), plus fixed guards at 85,
# 90, 95 and 99%. At 99% the agent must stop and ask before continuing. If
# several bands are crossed in one jump, only the most serious one speaks;
# the rest are marked silently.
#
# RAW-COUNT mode (window size UNKNOWN). The hook does NOT invent a window:
# faking a percentage against an assumed size is a silent fallback, and
# fail-loud forbids it (a wrong limit either screams STOP LAW at a real 20% or
# stays mute past a real 100%). It just reports the running token count once per
# 100k and leaves the judgement to the agent, which knows its own real window
# and decides when to hand off. No percentage, no close-out, no STOP LAW.
#
# Config (via env, e.g. "env" in .claude/settings.local.json):
#   CLAUDE_CONTEXT_LIMIT  window size in tokens; overrides model detection and
#                         forces PERCENTAGE mode (set it to give an unknown
#                         model a percentage instead of the raw count)
#   CLAUDE_CONTEXT_WARN   "soft,hard" percentages (default "70,80")
#
# Portable: Linux and macOS (no tac, no GNU-only flags). Requires jq.
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION=$(echo "$INPUT" | jq -r '.session_id // "nosession"')
{ [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; } && exit 0

emit() {
  jq -n --arg msg "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$msg}}'
}
once() {
  local mark="/tmp/claude-ctx-warn-${SESSION}-$1"
  [ -f "$mark" ] && return 1
  touch "$mark"
}

# Last real usage entry. grep streams the file and works on both GNU and BSD.
USED=$(grep '"input_tokens"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '
  .message.usage as $u |
  ($u.input_tokens // 0) +
  ($u.cache_read_input_tokens // 0) +
  ($u.cache_creation_input_tokens // 0)' 2>/dev/null)
[[ "$USED" =~ ^[0-9]+$ ]] || exit 0
[ "$USED" -eq 0 ] && exit 0

# Resolve the context-window size, in precedence order:
# 1) explicit CLAUDE_CONTEXT_LIMIT always wins (forces PERCENTAGE mode);
# 2) else map the session's model to its real window (table from Anthropic's
#    catalog as of 2026-07: current models are 1M, except Haiku 4.5 at 200k;
#    the [1m] tag catches any 1M session whose exact id is not listed);
# 3) UNKNOWN model => leave LIMIT empty and drop to RAW-COUNT mode below. We do
#    NOT fall back to a guessed size: assuming 200k (or any number) is the
#    silent fallback fail-loud forbids -- a model relevio cannot identify gets
#    raw token counts, and the agent applies its own window knowledge.
LIMIT="${CLAUDE_CONTEXT_LIMIT:-}"
if [ -z "$LIMIT" ]; then
  MODEL=$(grep -o '"model":"[^"]*"' "$TRANSCRIPT" 2>/dev/null | tail -1)
  case "$MODEL" in
    *haiku*)  LIMIT=200000 ;;
    *\[1m\]*|*fable*|*mythos*|*opus-5*|*sonnet-5*|*opus-4-6*|*opus-4-7*|*opus-4-8*|*sonnet-4-6*)
              LIMIT=1000000 ;;
  esac
fi

# RAW-COUNT mode: unknown window. Report the current 100k mark once. Only the
# mark just crossed speaks; usage climbs, so lower marks are already behind us.
# No percentage, no close-out thresholds, no STOP LAW: the decision is the
# agent's, since it -- not this hook -- knows the model's real window size.
if [ -z "$LIMIT" ]; then
  HUNDREDS=$(( USED / 100000 ))
  [ "$HUNDREDS" -lt 1 ] && exit 0
  once "k${HUNDREDS}" || exit 0
  emit "CONTEXT: ${USED} tokens used so far (past the $(( HUNDREDS * 100 ))k mark). relevio does not recognize this session's model, so it cannot compute a percentage of the context window, and it will not guess one (a wrong guess would either fire false alarms or stay silent past the real ceiling), so no percentage-based warnings will fire this session. You know your own window size: use this running count to decide when to close the session (write the handoff in docs/handoff/, append the INDEX.md row, commit and push, then a fresh session) and keep the user informed of where things stand. To switch to percentage warnings, set \"env\": {\"CLAUDE_CONTEXT_LIMIT\": \"<tokens>\"} in .claude/settings.local.json."
  exit 0
fi

# --- PERCENTAGE mode (window size known) ---
WARN="${CLAUDE_CONTEXT_WARN:-70,80}"
SOFT="${WARN%%,*}"
HARD="${WARN##*,}"
if ! [[ "$SOFT" =~ ^[0-9]+$ && "$HARD" =~ ^[0-9]+$ ]] || [ "$SOFT" -ge "$HARD" ]; then
  # Loud, but once: a misconfigured hook must not fake-work silently.
  once config && emit "relevio: CLAUDE_CONTEXT_WARN is invalid (\"$WARN\"). Expected two increasing percentages like \"70,80\". Context warnings are DISABLED until it is fixed; tell the user."
  exit 0
fi

# Backstop: if USED exceeds LIMIT the limit is PROVABLY wrong (a real window
# cannot be over 100% full). Correct it to 1M and say so once, loudly, instead
# of firing false alarms (evidence beats config, including a wrong explicit
# CLAUDE_CONTEXT_LIMIT).
if [ "$USED" -gt "$LIMIT" ]; then
  if [ "$USED" -le 1000000 ]; then
    once limitfix && emit "relevio: measured usage (${USED} tokens) exceeds the assumed context window of ${LIMIT} tokens, which is impossible in a real window; this session clearly runs a 1M-token window${CLAUDE_CONTEXT_LIMIT:+ (your explicit CLAUDE_CONTEXT_LIMIT=${CLAUDE_CONTEXT_LIMIT} looks wrong)}. Percentages now use 1,000,000 for this session. Tell the user to make it permanent with \"env\": {\"CLAUDE_CONTEXT_LIMIT\": \"1000000\"} in .claude/settings.local.json." && exit 0
    LIMIT=1000000
  else
    once config && emit "relevio: measured usage (${USED} tokens) exceeds even a 1M window. The context math is broken in this environment; warnings are DISABLED for this session. Tell the user."
    exit 0
  fi
fi
PCT=$(( USED * 100 / LIMIT ))

# Mark every band crossed; speak only the most serious one not yet emitted
# (info bands come first so soft/hard/guards win when crossed together).
NAMES=(i10 i20 i30 i40 i50 i60 soft hard g85 g90 g95 g99)
LEVELS=(10 20 30 40 50 60 "$SOFT" "$HARD" 85 90 95 99)
TOP=""
for i in "${!NAMES[@]}"; do
  [ "$PCT" -ge "${LEVELS[$i]}" ] || continue
  once "${NAMES[$i]}" && TOP="${NAMES[$i]}"
done
[ -z "$TOP" ] && exit 0

case "$TOP" in
  i10|i20|i30|i40|i50|i60)
        emit "CONTEXT: ${PCT}% of the context window used (${USED}/${LIMIT} tokens). Status update, no action needed." ;;
  soft) emit "CONTEXT: ${PCT}% of the context window used (${USED}/${LIMIT} tokens); you passed the ${SOFT}% mark. You still have good room to work, but start steering toward completion:
- Finish what is already in progress, and commit completed items as you go.
- You can still take on small, self-contained requests from the user; do not refuse work just because of this message.
- Avoid STARTING large multi-file changes or tasks that would need a big share of the remaining window to complete.
- Begin thinking about what you would hand off to the next session: what was done, what is pending, and any reasoning or understanding built up this session that would be hard to reconstruct from scratch (approaches you ruled out, subtle couplings you found, why the obvious fix does not work).
Nothing needs to be written down yet: a later message will tell you when to write the handoff, with complete instructions. Until then, keep working." ;;
  hard) emit "CONTEXT: ${PCT}% of the context window used (${USED}/${LIMIT} tokens); you passed the ${HARD}% mark. Time to close the session, and there is enough window left to do it well: do not rush or skip steps.
1. Finish the edit you are in the middle of and commit it. Start nothing new after this.
2. Write the handoff to docs/handoff/YYYY-MM-DD_<short-title>.md: what was done this session (with commit hashes, so the next session can read the work with git log), lessons learned (only real problems that took several attempts to solve; never invent one), pending work in priority order, and for anything left open that depended on understanding built up this session (approaches you tried and ruled out, why the obvious fix does not work, a subtle coupling you found), the REASONING and not just the title: the next session can re-read files cheaply, but cannot cheaply re-derive your conclusions. Append a row to docs/handoff/INDEX.md (append-only: never edit or delete old rows).
3. Run the project's checks (type-check, linter, tests: see CLAUDE.md), then commit and push.
4. Give the user the close-out, two commands, EACH in its own fenced code block so they copy it in one click: '/rename DD-MM-YY <short-title>' to rename this session, and '/relevio:kickoff' as the first message of a NEW session. State the branch you worked on and the handoff filename." ;;
  g85)  emit "CONTEXT: ${PCT}% of the context window used. If a handoff has already been written for this session, keep answers short and do no new work: auto-compact is getting close. If NO handoff exists yet, write it NOW: docs/handoff/YYYY-MM-DD_<short-title>.md with what was done (commit hashes), lessons that cost real effort, pending work in order and the reasoning behind anything left open; append a row to docs/handoff/INDEX.md; commit and push." ;;
  g90)  emit "CONTEXT: ${PCT}% of the context window used. Auto-compact is approaching. Answer briefly, do not read files or start anything new, and remind the user in your reply that this conversation is nearly full and new work belongs in a fresh session." ;;
  g95)  emit "CONTEXT: ${PCT}% of the context window used. Auto-compact is imminent. Give only short answers and warn the user in EVERY reply that this conversation is about to auto-compact." ;;
  g99)  emit "STOP: ${PCT}% of the context window used. Do NOT answer the user's pending request. Reply ONLY, in the user's language, that this conversation reached 99% of its context window, that one more exchange may trigger auto-compact and destroy its remaining detail, and ask if they are SURE they want to continue. Then wait for their explicit confirmation before doing anything else." ;;
esac
exit 0
