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
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (usage: relevio-migrate.sh [--dry-run])" ;;
  esac
done

TOP="$(relevio_top)"
cd "$TOP"
[ -d docs/handoff ] || die "docs/handoff/ does not exist: nothing to migrate"

# Header value of a field, empty if absent. Only the block above the first
# blank line is searched, so a body line starting with "Branch:" cannot win.
hdr() { awk -v k="$1" '/^[ \t]*$/ { exit } index($0, k ": ") == 1 { sub(/^[^:]*: /, ""); sub(/[ \t]+$/, ""); print; exit }' "$2"; }

PROBLEMS=0
CONVERTED=0
SKIPPED=0

for f in docs/handoff/*.md; do
  [ -f "$f" ] || continue
  case "${f##*/}" in INDEX.md) continue ;; esac
  case "${f##*/}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) ;; *) continue ;; esac

  # Already current? Then it is not this script's business.
  if parse_header "$f" < "$f" >/dev/null 2>&1; then
    SKIPPED=$((SKIPPED + 1))
    echo "  ok        ${f##*/} (already a v0.22 header)"
    continue
  fi

  raw_branch="$(hdr Branch "$f")"
  raw_commits="$(hdr Commits "$f")"
  if [ -z "$raw_branch" ] || [ -z "$raw_commits" ]; then
    echo "  PROBLEM   ${f##*/}: no Branch or no Commits line in the header; this is not a pre-v0.22 handoff, fix it by hand" >&2
    PROBLEMS=$((PROBLEMS + 1)); continue
  fi

  branch="${raw_branch%% *}"
  note="${raw_branch#"$branch"}"; note="${note# }"
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
  areas="$(hdr Areas "$f")"
  if [ -z "$areas" ]; then
    if [ "$commits" = none ]; then
      areas=none
    else
      range="$(range_of "$commits")"
      if [ -z "$range" ]; then
        echo "  PROBLEM   ${f##*/}: the range $commits no longer resolves (rebased or squashed?), so Areas cannot be derived; add an \"Areas:\" line by hand (or \"Areas: none\")" >&2
        PROBLEMS=$((PROBLEMS + 1)); continue
      fi
      # git log, not git diff: range_of collapses a root commit to a single
      # revision, which `git diff X X` would read as an empty change.
      areas="$(git log --format= --name-only "$range" 2>/dev/null | cut -d/ -f1-2 | sort -u | grep -v '^$' || true)"
      # A session that touched fifty files makes an unreadable board row;
      # collapse those to their top-level directory.
      if [ "$(printf '%s\n' "$areas" | grep -c '')" -gt 12 ]; then
        areas="$(printf '%s\n' "$areas" | cut -d/ -f1 | sort -u)"
      fi
      areas="$(printf '%s' "$areas" | paste -sd, - | sed 's/,/, /g')"
      [ -n "$areas" ] || areas=none
    fi
  fi

  if [ "$DRY" = yes ]; then
    echo "  would fix ${f##*/}: Branch: $branch | Commits: $commits | Areas: $areas"
    [ -n "$note" ] && echo "              (moves to the body: \"$note\")"
    CONVERTED=$((CONVERTED + 1))
    continue
  fi

  tmp="$f.relevio-tmp.$$"
  awk -v branch="$branch" -v commits="$commits" -v areas="$areas" -v note="$note" '
    BEGIN { inhdr = 1 }
    inhdr && /^[ \t]*$/ {
      inhdr = 0
      # Areas sits right after Commits in the canonical order.
      if (!seen_areas) print "Areas: " areas
      print ""
      if (note != "") { print "Branch note: " note; print "" }
      next
    }
    inhdr {
      line = $0; sub(/[ \t]+$/, "", line)
      if (index(line, "Branch: ")  == 1) { print "Branch: "  branch;  next }
      if (index(line, "Commits: ") == 1) { print "Commits: " commits; print "Areas: " areas; seen_areas = 1; next }
      if (index(line, "Areas: ")   == 1) { if (seen_areas) next; print "Areas: " areas; seen_areas = 1; next }
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
