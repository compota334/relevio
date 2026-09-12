#!/usr/bin/env bash
# relevio: which sessions touched a file or directory, and who has open work
# on it right now.
#
# Answers the question a new branch always raises: "I am about to code here,
# who was here before me, and is anybody in there at this moment?". Prior
# sessions come from the handoff catalog (their commit ranges are replayed
# against the path); open work comes from the branches that are not merged
# into the integration branch and changed the same path. An OPEN WORK row is
# a collision risk: that change is not in main yet, so it will not be in your
# branch either, and both of you are editing the same surface.
#
# Usage: relevio-trace.sh [--main <ref>] <path> [<path> ...]
#   Paths are git pathspecs relative to the repository root: a file, a
#   directory, or a glob.
#
# Exit 0 always when the lookup ran (an empty result is an answer, not an
# error). Exit 2 if a handoff header is malformed or the integration branch
# cannot be resolved.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-handoffs-lib.sh"

MAIN_ARG=""; PATHS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --main) [ $# -ge 2 ] || die "--main needs a ref"; MAIN_ARG="$2"; shift 2 ;;
    -h|--help) relevio_usage "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown argument: $1 (usage: relevio-trace.sh [--main <ref>] <path> ...)" ;;
    *) PATHS="${PATHS}${1}
"; shift ;;
  esac
done
[ -n "$PATHS" ] || die "no path given (usage: relevio-trace.sh [--main <ref>] <path> ...)"

TOP="$(relevio_top)"
resolve_main "$MAIN_ARG"
load_catalog
HERE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

# Everything except the per-path `git log` is path-independent, so it is
# resolved ONCE here instead of once per path: the state of each branch, and
# each handoff's commit range. Without this, tracing five paths across forty
# handoffs re-asks git the same questions two hundred times.
STATES=""   # branch \t state
for b in $(catalog_branches); do
  STATES="${STATES}${b}	$(branch_state "$b")
"
done
state_of() {
  printf '%s' "$STATES" | awk -F'\t' -v b="$1" '$1 == b { print $2; found = 1 }
                                                END { if (!found) print "merged" }'
}

ROWS=""     # file \t dev \t branch \t range \t note
while IFS='	' read -r p _date _session dev branch _areas commits _rest; do
  [ -n "$p" ] || continue
  [ "$commits" = none ] && continue
  st="$(state_of "$branch")"
  case "$st" in
    gone)   note="branch gone" ;;
    merged) note="merged" ;;
    *)      note="open" ;;
  esac
  range="$(range_of "$commits")"
  # The hashes no longer resolve. Say so rather than silently omitting a
  # session that may well have touched this path. The sentinel matters: tab is
  # an IFS whitespace character, so an empty field here would be swallowed on
  # the way back in and shift the note into range, which silently discarded
  # exactly the row this branch exists to print.
  if [ -z "$range" ]; then
    range="$RELEVIO_NONE"
    note="range unresolvable (rebased or squashed?)"
  fi
  ROWS="${ROWS}${p##*/}	${dev}	${branch}	${range}	${note}
"
done <<EOF
$CATALOG
EOF

trace_one() {
  local p="$1" file dev branch range note hits b rows="" open_rows=""
  while IFS='	' read -r file dev branch range note; do
    [ -n "$file" ] || continue
    if [ "$range" = "$RELEVIO_NONE" ]; then
      rows="${rows}handoff	${branch}	${file}	${dev}	?	${note}
"
      continue
    fi
    hits="$(git rev-list --count "$range" -- "$p" 2>/dev/null || echo 0)"
    [ "${hits:-0}" -gt 0 ] || continue
    rows="${rows}handoff	${branch}	${file}	${dev}	${hits}	${note}
"
  done <<EOF
$ROWS
EOF

  # Open work: unmerged branches that changed this path. This is the part a
  # naive `git log` on your own branch can never show you.
  while IFS='	' read -r b state; do
    [ -n "$b" ] || continue
    [ "$state" = open ] || continue
    tip="$(branch_tip "$b")"
    hits="$(git rev-list --count "$MAIN..$tip" -- "$p" 2>/dev/null || echo 0)"
    [ "${hits:-0}" -gt 0 ] || continue
    note="collision risk"
    [ "$b" = "$HERE" ] && note="your own branch"
    open_rows="${open_rows}OPEN WORK	${b}	${tip}	$(devs_of "$b")	${hits}	${note}
"
  done <<EOF
$STATES
EOF

  printf '## %s\n\n' "$p"
  if [ -z "$rows" ] && [ -z "$open_rows" ]; then
    printf '_No handoff and no open branch touched `%s`._\n\n' "$p"
    return 0
  fi
  echo '| Kind | Branch | Handoff / tip | Dev | Commits touching | Note |'
  echo '|------|--------|---------------|-----|------------------|------|'
  printf '%s%s' "$open_rows" "$rows" | grep -v '^$' \
    | awk -F'\t' '{ printf("| %s | `%s` | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6) }'
  echo
}

while IFS= read -r one; do
  [ -n "$one" ] || continue
  trace_one "$one"
done <<EOF
$PATHS
EOF
