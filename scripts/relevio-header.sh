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
#                    v0.25); Resume then says so, in the open
#   --since <date>   when the session began, in any form git accepts ("2026-10-15
#                    09:30", "3 hours ago"); needed only when relevio holds no
#                    start record for the session
#
# Exit 0 prints the header. Exit 2 names what is missing and how to supply it;
# nothing is ever filled in with a guess.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-handoffs-lib.sh"

ID=""; NO_ID=no; SINCE=""; EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || die "--since needs a date"; SINCE="$2"; shift 2 ;;
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
  [ -n "$ID" ] || die "no session id given. relevio states it at session start, on the line beginning \"SESSION ID\". If that line is not in your context, the session began before relevio v0.25: rerun with --no-session-id, and say so to the user."
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
if [ -z "$SINCE" ]; then
  if [ "$NO_ID" = yes ]; then
    die "with --no-session-id there is no start record to read, so give the session's start with --since \"<date>\" (ask the user if you do not know it)."
  fi
  rec="$(cd "$(git rev-parse --git-common-dir)" && pwd)/relevio/sessions/$ID"
  [ -r "$rec" ] || die "relevio holds no record of when session $ID began (it started before relevio v0.25, or in another clone). Ask the user when this session started and rerun with --since \"<date>\"."
  read -r START AT < "$rec" || true
  printf '%s' "${START:-}" | grep -Eq '^[0-9]+$' || die "the start record $rec is not a timestamp. Rerun with --since \"<date>\"."
  SINCE="@$START"
  # The commit HEAD stood on when the session began. Everything reachable from
  # it predates the session, even a commit made in the same second.
  if [ -n "${AT:-}" ] && git rev-parse -q --verify "$AT^{commit}" >/dev/null 2>&1; then EXCLUDE="^$AT"; fi
fi
ME="$(git config --get user.email 2>/dev/null || true)"
[ -n "$ME" ] || die "git has no user.email here, so relevio cannot tell your commits from the ones you pulled. Set it (git config user.email ...) and rerun."
# Committed by you, after the start, and on the branch you are recording.
# Commits pulled from teammates during the session carry their own email; a
# rebase re-commits yours with a fresh date, so they still count.
OURS="$(git log --reverse --since="$SINCE" --format='%h %ce' HEAD ${EXCLUDE:+"$EXCLUDE"} 2>/dev/null \
  | awk -v me="$ME" '$2 == me { print $1 }')" \
  || die "git could not read the history since \"$(relevio_safe "$SINCE")\". Check the --since value."
if [ -z "$OURS" ]; then
  COMMITS=none
else
  COMMITS="$(printf '%s\n' "$OURS" | head -1)..$(printf '%s\n' "$OURS" | tail -1)"
fi
AREAS="$(areas_for_range "$COMMITS")" \
  || die "the range $COMMITS does not resolve, so Areas cannot be derived from it."

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
