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
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

trace_one() {
  local p="$1" rec file branch commits dev range hits note tip rows="" open_rows=""
  # Prior sessions: a handoff touched the path when its own commit range
  # contains at least one commit that changed it.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    file="$(fld "$rec" 1)"; file="${file##*/}"
    dev="$(fld "$rec" 4)"; branch="$(fld "$rec" 5)"; commits="$(fld "$rec" 7)"
    if [ "$commits" = "none" ]; then continue; fi
    range="$(range_of "$commits")"
    if [ -z "$range" ]; then
      # The hashes no longer resolve. Say so rather than silently omitting a
      # session that may well have touched this path.
      rows="${rows}handoff	${branch}	${file}	${dev}	?	range unresolvable (rebased or squashed?)
"
      continue
    fi
    hits="$(git log --format=%h "$range" -- "$p" 2>/dev/null | grep -c '' || true)"
    [ "${hits:-0}" -gt 0 ] || continue
    tip="$(branch_tip "$branch")"
    if [ -z "$tip" ]; then note="branch gone"
    elif git merge-base --is-ancestor "$tip" "$MAIN" 2>/dev/null; then note="merged"
    else note="open"
    fi
    rows="${rows}handoff	${branch}	${file}	${dev}	${hits}	${note}
"
  done <<EOF
$CATALOG
EOF

  # Open work: unmerged branches that changed this path. This is the part a
  # naive `git log` on your own branch can never show you.
  local b dev
  for b in $(catalog_branches); do
    tip="$(branch_tip "$b")"
    [ -n "$tip" ] || continue
    git merge-base --is-ancestor "$tip" "$MAIN" 2>/dev/null && continue
    hits="$(git log --format=%h "$MAIN..$tip" -- "$p" 2>/dev/null | grep -c '' || true)"
    [ "${hits:-0}" -gt 0 ] || continue
    note="collision risk"
    [ "$b" = "$HERE" ] && note="your own branch"
    dev="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b { print $4 }' | sort -u | paste -sd, - | sed 's/,/, /g')"
    open_rows="${open_rows}OPEN WORK	${b}	${tip}	${dev}	${hits}	${note}
"
  done

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
