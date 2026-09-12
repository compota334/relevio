#!/usr/bin/env bash
# relevio: convert handoff headers written before v0.22 to the parseable form.
#
# Until v0.21 the header was read by humans only, so `Branch:` could carry
# prose ("main (worked from a worktree, all pushed)") and `Commits:` could
# carry a suffix ("aeb5eee..2bf8667 (10 commits)"). Since v0.22 the header is
# parsed by relevio-index.sh, which needs those two fields bare, and needs a
# new `Areas:` field naming the surfaces the session touched.
#
# This script does that conversion once, per repository:
#   - Branch: keeps the first token, moves the rest into the body as a
#     "Branch note:" line, so no explanation is lost.
#   - Commits: keeps the bare <first>..<last>, drops any suffix.
#   - Areas: derived from the commit range with git, never invented. If the
#     range no longer resolves (rebased or squashed history), the file is
#     reported and left alone for you to fill in by hand.
# A handoff that already has the current header is left untouched, so running
# this twice changes nothing.
#
# It only converts the handoffs PRESENT IN THIS WORKING TREE. Handoffs living
# on other branches are converted by running it once on each of those
# branches, which is also where their fix belongs: the commit that carries a
# handoff is the commit that should carry its migration.
#
# Usage: relevio-migrate.sh [--dry-run]
#
# Exit 0 = every handoff in this working tree now has a v0.22 header.
# Exit 2 = at least one file could not be converted (it says which and why);
#          the files it could convert are still converted.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-handoffs-lib.sh"

DRY=no
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=yes; shift ;;
    -h|--help) relevio_usage "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1 (usage: relevio-migrate.sh [--dry-run])" ;;
  esac
done

TOP="$(relevio_top)"
cd "$TOP"
[ -d docs/handoff ] || die "docs/handoff/ does not exist: nothing to migrate"

# The three fields the migration reads, in one pass. Only the block above the
# first blank line is searched, so a body line starting with "Branch:" cannot
# win. This is the tolerant reader; parse_header in the library is the strict
# one, and the two agree on where the header block ends.
read_legacy_header() {
  awk '
    /^[ \t]*$/ { exit }
    index($0, "Branch: ") == 1 || index($0, "Commits: ") == 1 || index($0, "Areas: ") == 1 {
      k = $0; sub(/:.*/, "", k)
      v = $0; sub(/^[^:]*: /, "", v); sub(/[ \t]+$/, "", v)
      if (!(k in seen)) { seen[k] = 1; val[k] = v }
    }
    END { printf("%s\t%s\t%s\n", val["Branch"], val["Commits"], val["Areas"]) }' "$1"
}

PROBLEMS=0
CONVERTED=0
SKIPPED=0

for f in docs/handoff/*.md; do
  [ -f "$f" ] || continue
  case "${f##*/}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.md) ;; *) continue ;; esac

  # Already current? Then it is not this script's business.
  if parse_header "$f" < "$f" >/dev/null 2>&1; then
    SKIPPED=$((SKIPPED + 1))
    echo "  ok        ${f##*/} (already a v0.22 header)"
    continue
  fi

  IFS='	' read -r raw_branch raw_commits areas <<EOF
$(read_legacy_header "$f")
EOF
  if [ -z "$raw_branch" ] || [ -z "$raw_commits" ]; then
    echo "  PROBLEM   ${f##*/}: no Branch or no Commits line in the header; this is not a pre-v0.22 handoff, fix it by hand" >&2
    PROBLEMS=$((PROBLEMS + 1)); continue
  fi

  branch="${raw_branch%% *}"
  note="${raw_branch#"$branch"}"; note="${note# }"
  # The prose was usually parenthesised because it sat inside a field; as a
  # body line it reads better without the wrapping pair.
  case "$note" in "("*")") note="${note#\(}"; note="${note%\)}" ;; esac
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "  PROBLEM   ${f##*/}: Branch starts with \"$branch\", which is not a valid branch name; fix it by hand" >&2
    PROBLEMS=$((PROBLEMS + 1)); continue
  fi

  if [ "$raw_commits" = "none" ]; then
    commits=none
  else
    commits="$(printf '%s' "$raw_commits" | grep -oE '[0-9a-f]{7,40}\.\.[0-9a-f]{7,40}' | head -1 || true)"
    if [ -z "$commits" ]; then
      echo "  PROBLEM   ${f##*/}: Commits is \"$raw_commits\", which holds no <first>..<last> range; set it by hand (or to \"none\")" >&2
      PROBLEMS=$((PROBLEMS + 1)); continue
    fi
  fi

  # Areas comes from git or not at all. Inventing it would put a wrong answer
  # into the one field the lane board uses to say what a branch is touching.
  if [ -z "$areas" ] && ! areas="$(areas_for_range "$commits")"; then
    echo "  PROBLEM   ${f##*/}: the range $commits no longer resolves (rebased or squashed?), so Areas cannot be derived; add an \"Areas:\" line by hand (or \"Areas: none\")" >&2
    PROBLEMS=$((PROBLEMS + 1)); continue
  fi

  if [ "$DRY" = yes ]; then
    echo "  would fix ${f##*/}: Branch: $branch | Commits: $commits | Areas: $areas"
    [ -n "$note" ] && echo "              (moves to the body: \"$note\")"
    CONVERTED=$((CONVERTED + 1))
    continue
  fi

  tmp="$f.relevio-tmp.$$"
  # Commits is guaranteed present (checked above), so Areas is always emitted
  # right after it, in the canonical field order.
  awk -v branch="$branch" -v commits="$commits" -v areas="$areas" -v note="$note" '
    BEGIN { inhdr = 1 }
    inhdr && /^[ \t]*$/ {
      inhdr = 0
      print ""
      if (note != "") { print "Branch note: " note; print "" }
      next
    }
    inhdr {
      line = $0; sub(/[ \t]+$/, "", line)
      if (index(line, "Areas: ")   == 1) next   # re-emitted after Commits
      if (index(line, "Branch: ")  == 1) { print "Branch: "  branch;  next }
      if (index(line, "Commits: ") == 1) { print "Commits: " commits; print "Areas: " areas; next }
      print line; next
    }
    { print }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"

  if parse_header "$f" < "$f" >/dev/null; then
    echo "  fixed     ${f##*/}: Branch: $branch | Commits: $commits | Areas: $areas"
    CONVERTED=$((CONVERTED + 1))
  else
    echo "  PROBLEM   ${f##*/}: converted but the result still does not parse (see the error above)" >&2
    PROBLEMS=$((PROBLEMS + 1))
  fi
done

echo "relevio-migrate: $CONVERTED converted, $SKIPPED already current, $PROBLEMS need a hand"
[ "$PROBLEMS" -eq 0 ] || exit 2
