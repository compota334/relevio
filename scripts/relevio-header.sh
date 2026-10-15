#!/usr/bin/env bash
# relevio: print the metadata header for this session's handoff.
#
# Six of the nine header fields are facts git and the host already know, and
# an agent writing them by hand gets them wrong in ways no parser can catch: it
# copies the previous handoff's header as a template, does not know where its
# own session started, spells the dev's name differently every time, and finds
# its session id by guessing (the newest transcript in the project folder is
# the OTHER conversation whenever two are open). So this script computes Date,
# Dev, Branch, Commits, Areas and Resume, and leaves the agent only what needs
# judgement: Session, Topics and Summary, marked "<fill in: ...>".
#
#   Date     today
#   Dev      git config relevio.dev, set once per clone (never guessed)
#   Branch   the branch checked out here (a detached HEAD is refused)
#   Commits  the commits on HEAD that you committed since this session began;
#            the start is what the session-start hook recorded for this session
#            id (the time, and the commit HEAD stood on), or --since when there
#            is no record
#   Areas    derived from that range, as relevio-areas.sh does
#   Resume   built from the session id: claude --resume <uuid> for Claude
#            Code, the sess_ id for ZCode
#
# Usage: relevio-header.sh <session-id> [--since <date>]
#        relevio-header.sh --no-session-id [--since <date>]
#   <session-id>     the id relevio gave at session start, on the line
#                    beginning "SESSION ID"
#   --no-session-id  the session has no id to record (it began before relevio
#                    v0.24.5); Resume then says so, in the open
#   --since <date>   when the session began, in any form git accepts ("2026-10-15
#                    09:30", "3 hours ago"); needed only when relevio holds no
#                    start record for the session
#
# Exit 0 prints the header. Exit 2 names what is missing and how to supply it;
# nothing is ever filled in with a guess.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-handoffs-lib.sh"

ID=""; NO_ID=no; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ -n "${2:-}" ] || die "--since needs a date"; SINCE="$2"; shift 2 ;;
    --no-session-id) NO_ID=yes; shift ;;
    -h|--help) relevio_usage "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown argument: $1 (usage: relevio-header.sh <session-id> [--since <date>])" ;;
    *) [ -z "$ID" ] || die "more than one session id given"; ID="$1"; shift ;;
  esac
done

TOP="$(relevio_top)"
cd "$TOP"

# --- Resume, from the id alone ------------------------------------------------
if [ "$NO_ID" = yes ]; then
  [ -z "$ID" ] || die "give a session id or --no-session-id, not both"
  RESUME="unknown (this session had no id to record)"
else
  [ -n "$ID" ] || die "no session id given. relevio states it at session start, on the line beginning \"SESSION ID\". If that line is not in your context, the session began before relevio v0.24.5: rerun with --no-session-id, and say so to the user."
  if printf '%s' "$ID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    RESUME="claude --resume $ID"
  elif printf '%s' "$ID" | grep -Eq '^sess_[A-Za-z0-9_-]+$'; then
    RESUME="$ID (reopen it from ZCode's session list)"
  else
    die "\"$(relevio_safe "$ID")\" is not a session id: a Claude Code id is a UUID, a ZCode id is sess_ followed by letters, digits, '-' and '_'. Use the exact id from the line beginning \"SESSION ID\"."
  fi
fi

# --- Dev, recorded once per clone ---------------------------------------------
DEV="$(git config --get relevio.dev 2>/dev/null || true)"
[ -n "$DEV" ] || die "relevio does not know this developer's short name, which the Dev field needs, and it will not guess one (a name spelled two ways splits one person's sessions in two). Ask the user for it, then record it once for this clone:

    git config relevio.dev NICO

(their own short name, in capitals)."
printf '%s' "$DEV" | grep -Eq '^[A-Z][A-Z0-9_-]*$' \
  || die "git config relevio.dev holds \"$(relevio_safe "$DEV")\", which is not a short name in capitals (letters, digits, '_' or '-', such as NICO or ANA_B). Ask the user for the right one and record it with: git config relevio.dev <NAME>"

# --- Branch -------------------------------------------------------------------
BRANCH="$(git branch --show-current 2>/dev/null || true)"
[ -n "$BRANCH" ] || die "this checkout is on a detached HEAD, so there is no branch to record. A handoff names the branch its work lives on: switch to that branch first (the close-out detaches only AFTER the handoff is pushed)."

# --- Commits, from when the session began ---------------------------------------
# The start, as a timestamp, plus the commit HEAD stood on when the session
# began, when relevio recorded one. git's own --since is not used to walk the
# history: it may stop at the first commit older than the date, and a commit
# with an older date (an amend, a cherry-pick, a skewed clock) would hide this
# session's earlier commits behind it. The date is applied as a filter instead.
AT=""
if [ -n "$SINCE" ]; then
  START="$(git rev-parse --since="$SINCE" 2>/dev/null | sed -n 's/^--max-age=//p')"
  printf '%s' "$START" | grep -Eq '^[0-9]+$' || die "git does not read \"$(relevio_safe "$SINCE")\" as a date. Use a form such as \"2026-10-15 09:30\"."
else
  if [ "$NO_ID" = yes ]; then
    die "with --no-session-id there is no start record to read, so give the session's start with --since \"<date>\" (ask the user if you do not know it)."
  fi
  rec="$(cd "$(git rev-parse --git-common-dir)" && pwd)/relevio/sessions/$ID"
  [ -r "$rec" ] || die "relevio holds no record of when session $ID began (it started before relevio v0.24.5, or in another clone). Ask the user when this session started and rerun with --since \"<date>\"."
  read -r START AT < "$rec" || true
  printf '%s' "${START:-}" | grep -Eq '^[0-9]+$' || die "the start record $rec is not a timestamp. Rerun with --since \"<date>\"."
  # Everything reachable from the start commit predates the session, even a
  # commit made in the same second. A start commit that no longer exists means
  # that boundary is gone: say so instead of counting by time alone.
  if [ -n "${AT:-}" ] && ! git rev-parse -q --verify "$AT^{commit}" >/dev/null 2>&1; then
    die "the commit this session started on (${AT:0:12}) no longer exists in this clone, so relevio cannot tell where the session's commits begin. Ask the user when the session started and rerun with --since \"<date>\"."
  fi
fi
# Said out loud, because a mistyped --since is still a valid git date.
echo "relevio-header: counting your commits since $(date -d "@$START" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$START" '+%Y-%m-%d %H:%M')" >&2
ME="$(git config --get user.email 2>/dev/null || true)"
[ -n "$ME" ] || die "git has no user.email here, so relevio cannot tell your commits from the ones you pulled. Set it (git config user.email ...) and rerun."
# Committed by you, after the start, on the branch you are recording, and not a
# merge. Commits pulled from teammates carry their own email; a rebase
# re-commits yours with a fresh date, so they still count; and a merge commit
# you made by pulling is yours only in name: its content is the teammates'.
OURS="$(git log --reverse --no-merges --format='%h %ct %ce' HEAD ${AT:+"^$AT"} 2>/dev/null \
  | awk -v me="$ME" -v start="$START" '$2 >= start && $3 == me { print $1 }')" \
  || die "git could not read this branch's history."
if [ -z "$OURS" ]; then
  COMMITS=none
else
  COMMITS="$(printf '%s\n' "$OURS" | head -1)..$(printf '%s\n' "$OURS" | tail -1)"
fi
# From the session's own commits only: the range between the first and the
# last can hold a teammate's commit, whose paths are not this session's.
# shellcheck disable=SC2086  # one argument per commit hash
AREAS="$(areas_for_commits $OURS)"

cat <<EOF
Session: <fill in: DD-MM-YY short title, the name /rename will give this conversation>
Date: $(date +%Y-%m-%d)
Dev: $DEV
Branch: $BRANCH
Commits: $COMMITS
Areas: $AREAS
Resume: $RESUME
Topics: <fill in: comma-separated lowercase tags>
Summary: <fill in: one line, and no vertical bar character>
EOF
