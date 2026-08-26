#!/bin/bash
# relevio v0.21.2
# relevio: context warning for the agent.
# The model is blind to its own window %: this hook un-blinds it by reading the
# usage from the transcript and injecting a notice via additionalContext
# (PostToolUse). Each band warns ONCE per session.
#
# DESIGN RULE (anti-anticipation): every instruction travels WITH the event
# that triggers it, never before. The checkpoints are a bare number with no
# talk of closing (a negation like "not a close signal" still plants the
# idea); the soft message frames the moment as the session's sweet spot (max
# understanding loaded + plenty of room) without asking for the handoff; the
# hard message carries the FULL close-out checklist, because it is the first
# time the agent needs it. An agent that learns the close-out early starts
# anticipating it (observed: sessions closing at 60% because they knew a
# warning existed at 70%).
#
# Every percentage message states used AND free tokens: agents that only see
# a percentage overestimate how full they are (observed: an agent at 30%
# recommending closure "to be safe"); the absolute free count makes the
# remaining room concrete. The window is never presented as a reason to act:
# the task decides, the hook only informs, and instructions arrive only in
# the message of the band that needs them.
#
# The usage is read by ONE READER PER HOST AGENT (Claude Code: the session's
# JSONL transcript; ZCode: its local SQLite usage table), and everything from
# the window table down is shared. A host relevio cannot read at all fails
# loud, once, instead of leaving the agent waiting for reports forever.
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
PAYLOAD_MODEL=$(echo "$INPUT" | jq -r '.model // empty')

emit() {
  jq -n --arg msg "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$msg}}'
}
once() {
  local mark="/tmp/claude-ctx-warn-${SESSION}-$1"
  [ -f "$mark" ] && return 1
  touch "$mark"
}
# The one loud OFF notice, shared by every structural failure to read usage:
# fired once per session, never silence (an agent waiting for reports that
# cannot arrive is the exact failure relevio exists to prevent). The handoff
# pointer must travel in this very message, like the RAW-COUNT notice: no
# later band will ever fire in this host to carry it.
off_notice() {
  once foreign || exit 0
  emit "relevio: $1 Usage reporting is OFF for this whole session: no token counts and no percentage warnings will arrive, and silence tells you NOTHING about the window. Never guess or invent a usage figure. You know your own model and window: use that knowledge to decide when to wrap up the session with a handoff (write it in docs/handoff/, append the INDEX.md row, commit and push, then a fresh session), and keep the user informed of where things stand."
  exit 0
}

# --- Read the usage: one reader per host agent ------------------------------
# Everything below the readers (window resolution, bands, messages) is
# host-agnostic: it only needs USED (tokens, integer) and MODEL (an id
# wrapped in double quotes for the exact-match table). Each reader fills
# them or handles its own failure; a reader that cannot possibly work fails
# LOUD via off_notice, a merely-empty read this early in the session stays
# quiet and retries on the next tool call.
USED=""; MODEL=""
if [ "${PAYLOAD_MODEL#builtin:}" != "$PAYLOAD_MODEL" ]; then
  # ZCode (Z.ai): the payload names a builtin model. Its transcript_path is
  # a DECOY for usage purposes (a throwaway per-event temp file with no
  # token data inside; measured, see docs/2026-08-26_zcode-investigation.md),
  # so the real usage is read from ZCode's local SQLite, keyed by the
  # session_id the payload carries. Latest computed_total_tokens (input +
  # output of the last model call) is the context size right now. python3
  # instead of the sqlite3 CLI: the CLI is often absent, python3 rarely is.
  ZCODE_DB="${RELEVIO_ZCODE_DB:-$HOME/.zcode/cli/db/db.sqlite}"
  [ -f "$ZCODE_DB" ] || off_notice "this is a ZCode session, but ZCode's usage database is not where relevio expects it (${ZCODE_DB}), so context-window usage cannot be measured. Point RELEVIO_ZCODE_DB at the db.sqlite to fix it."
  command -v python3 >/dev/null 2>&1 || off_notice "this is a ZCode session, but python3 is not available, and relevio needs it to read ZCode's usage database, so context-window usage cannot be measured."
  USED=$(python3 - "$ZCODE_DB" "$SESSION" <<'PY' 2>/dev/null
import sqlite3, sys
con = sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True)
row = con.execute(
    'SELECT computed_total_tokens FROM model_usage'
    ' WHERE session_id=? ORDER BY rowid DESC LIMIT 1',
    (sys.argv[2],)).fetchone()
print(row[0] if row and row[0] is not None else '')
PY
) || off_notice "this is a ZCode session, but reading ZCode's usage database failed (${ZCODE_DB}), so context-window usage cannot be measured."
  # An empty result with a healthy db is the normal early-turn state (no
  # model call recorded yet): stay quiet, the next tool call retries.
  MODEL="\"$(printf '%s' "$PAYLOAD_MODEL" | tr '[:upper:]' '[:lower:]' | sed 's|^builtin:zai/||; s|^builtin:||')\""
elif [ -n "$TRANSCRIPT" ]; then
  # Claude Code: usage lives in the session's JSONL transcript. A path that
  # is present but points to a missing file is transient, not structural:
  # stay quiet. Last real usage entry wins; grep streams the file and works
  # on both GNU and BSD.
  [ ! -f "$TRANSCRIPT" ] && exit 0
  USED=$(grep '"input_tokens"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '
    .message.usage as $u |
    ($u.input_tokens // 0) +
    ($u.cache_read_input_tokens // 0) +
    ($u.cache_creation_input_tokens // 0)' 2>/dev/null)
  MODEL=$(grep -o '"model":"[^"]*"' "$TRANSCRIPT" 2>/dev/null | tail -1)
else
  # FOREIGN HOST: no transcript_path at all means a host relevio does not
  # know how to read (e.g. Devin loads .claude/ hooks but sends no
  # transcript). session-start armed the agent with a methodology whose
  # reports would then never arrive: say so, loudly, once.
  off_notice "this host agent sends no transcript path in its hook payloads, so relevio cannot measure context-window usage here."
fi
[[ "$USED" =~ ^[0-9]+$ ]] || exit 0
[ "$USED" -eq 0 ] && exit 0

# Resolve the context-window size, in precedence order:
# 1) explicit CLAUDE_CONTEXT_LIMIT always wins (forces PERCENTAGE mode);
# 2) else map the session's MODEL (set by the reader above) to its real
#    window (Anthropic catalog as of 2026-07: current models are 1M, except
#    Haiku 4.5 at 200k; the [1m] tag catches any 1M session whose exact id
#    is not listed; GLM windows per Z.ai's catalog as of 2026-08);
# 3) UNKNOWN model => leave LIMIT empty and drop to RAW-COUNT mode below. We do
#    NOT fall back to a guessed size: assuming 200k (or any number) is the
#    silent fallback fail-loud forbids -- a model relevio cannot identify gets
#    raw token counts, and the agent applies its own window knowledge.
LIMIT="${CLAUDE_CONTEXT_LIMIT:-}"
if [ -z "$LIMIT" ]; then
  case "$MODEL" in
    *haiku*)  LIMIT=200000 ;;
    *\[1m\]*|*fable*|*mythos*|*opus-5*|*sonnet-5*|*opus-4-6*|*opus-4-7*|*opus-4-8*|*sonnet-4-6*)
              LIMIT=1000000 ;;
    # GLM (Z.ai): the GLM Coding Plan plugs these models into Claude Code, so
    # sessions carry glm ids in the transcript. Matched EXACTLY
    # (quote-delimited), not loosely: GLM variants differ in window size
    # (4.5-air is 128k, 4.6 is 200k, 5.2/5.3 are 1M per Z.ai's catalog as of
    # 2026-08), so a loose *glm-5.2* could catch a future -air variant with a
    # different window. An unlisted glm id drops to RAW-COUNT mode, as any
    # unknown model does.
    *\"glm-5.2\"*|*\"glm-5.3\"*) LIMIT=1000000 ;;
    *\"glm-5.1\"*|*\"glm-4.6\"*) LIMIT=200000 ;;
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
  emit "CONTEXT: ${USED} tokens of your context window used so far (past the $(( HUNDREDS * 100 ))k mark). relevio does not recognize this session's model, so it cannot compute a percentage of the context window, and it will not guess one (a wrong guess would either fire false alarms or stay silent past the real ceiling), so no percentage-based warnings will fire this session. You know your own window size: use this running count to decide when to close the session (write the handoff in docs/handoff/, append the INDEX.md row, commit and push, then a fresh session) and keep the user informed of where things stand. To switch to percentage warnings, set \"env\": {\"CLAUDE_CONTEXT_LIMIT\": \"<tokens>\"} in .claude/settings.local.json."
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
FREE=$(( LIMIT - USED ))

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
        emit "CONTEXT: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, ${FREE} still free. Status update, no action needed." ;;
  soft) emit "CONTEXT: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, ${FREE} still free; you passed the ${SOFT}% mark. You are in the sweet spot of the session: a full session's worth of hard-won understanding is loaded in your context, AND a large share of the window (${FREE} tokens) is still free. That combination is at its peak right now, so put it to work:
- Focus on finishing and polishing what is already in progress, committing completed items as you go.
- New requests from the user are welcome at any size: the user decides what is worth starting, and the token count above tells you how much room there is; size your approach to it.
- Begin thinking about what you would hand off to the next session: what was done, what is pending, and any reasoning or understanding built up this session that would be hard to reconstruct from scratch (approaches you ruled out, subtle couplings you found, why the obvious fix does not work).
Nothing needs to be written down yet: a later message will tell you when to write the handoff, with complete instructions. Until then, keep working." ;;
  hard) emit "CONTEXT: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, ${FREE} still free; you passed the ${HARD}% mark. Time to close the session, and ${FREE} tokens is enough room to do it well: no rushing, no skipped steps.
1. Bring the work in progress to a coherent, safe stopping point at full quality (do not abandon anything mid-change). Start nothing new after this.
2. Then write the handoff, while this session's understanding is still fully loaded, to docs/handoff/YYYY-MM-DD_<short-title>.md: what was done this session (cite the hashes of commits already made, so the next session can read the work with git log), lessons learned (only real problems that took several attempts to solve; never invent one), pending work in priority order, and for anything left open that depended on understanding built up this session (approaches you tried and ruled out, why the obvious fix does not work, a subtle coupling you found), the REASONING and not just the title: the next session can re-read files cheaply, but cannot cheaply re-derive your conclusions. Append a row to docs/handoff/INDEX.md (append-only: never edit or delete old rows).
3. Run the project's checks (type-check, linter, tests: see CLAUDE.md), then commit everything, work and handoff included, and push.
4. Give the user the close-out, two commands, EACH in its own fenced code block so they copy it in one click: '/rename DD-MM-YY <short-title>' to rename this session, and '/relevio:kickoff' as the first message of a NEW session. State the branch you worked on and the handoff filename." ;;
  g85)  emit "CONTEXT: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, ${FREE} still free. If a handoff has already been written for this session, keep answers short and do no new work: auto-compact is getting close. If NO handoff exists yet, write it NOW: docs/handoff/YYYY-MM-DD_<short-title>.md with what was done (commit hashes), lessons that cost real effort, pending work in order and the reasoning behind anything left open; append a row to docs/handoff/INDEX.md; commit and push." ;;
  g90)  emit "CONTEXT: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, ${FREE} still free. Auto-compact is approaching. Answer briefly, do not read files or start anything new, and remind the user in your reply that this conversation is nearly full and new work belongs in a fresh session." ;;
  g95)  emit "CONTEXT: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, only ${FREE} still free. Auto-compact is imminent. Give only short answers and warn the user in EVERY reply that this conversation is about to auto-compact." ;;
  g99)  emit "STOP: ${PCT}% of your context window used: ${USED} of ${LIMIT} tokens, only ${FREE} still free. Do NOT answer the user's pending request. Reply ONLY, in the user's language, that this conversation reached 99% of its context window, that one more exchange may trigger auto-compact and destroy its remaining detail, and ask if they are SURE they want to continue. Then wait for their explicit confirmation before doing anything else." ;;
esac
exit 0
