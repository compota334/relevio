#!/usr/bin/env bash
# relevio: shared library for the handoff scripts (relevio-index.sh,
# relevio-trace.sh, relevio-migrate.sh). Source it, do not run it.
#
# Everything here is POSIX awk + bash 3.2 + git. No jq, no GNU-only flags,
# no `tac`, no `sort -V`, no `sed -i`, no `readlink -f`: the scripts run on
# Linux and on macOS with its stock bash 3.2 and BSD awk.
#
# The design rule is fail-loud: a malformed handoff header aborts the whole
# run naming the file and the field. Nothing is guessed, nothing is skipped
# silently, and no output file is touched until every header has parsed.

[ "${BASH_SOURCE[0]}" != "${0}" ] || {
  echo "relevio-handoffs-lib.sh is a library: run relevio-index.sh, relevio-trace.sh or relevio-migrate.sh instead." >&2
  exit 2
}

# The nine header fields, in canonical order. Order is NOT enforced when
# parsing (an agent may reorder without breaking the catalog); this list is
# what the parser requires to be present, and what relevio-migrate.sh writes.
RELEVIO_FIELDS="Session Date Dev Branch Commits Areas Resume Topics Summary"
REPO_UNBORN=no

# Byte ordering everywhere. `sort` collates differently per locale, so without
# this two devs regenerating the same index on the same commits would produce
# two different files and a pointless merge conflict.
export LC_ALL=C

die() { echo "ERROR: $*" >&2; exit 2; }

# The repository root, from anywhere inside it (a worktree included).
relevio_top() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

# --- the integration branch -------------------------------------------------
# Everything the board reports (merged / open / ahead) is measured against
# this ref. There is no fallback to a guess: if it cannot be found, the run
# stops and says which ref it looked for and how to point it elsewhere.
resolve_main() {
  MAIN="${1:-${RELEVIO_MAIN:-}}"
  # A repository with no commits at all has no branches to compare, so there
  # is no integration branch to find and no lane that could be open. This is
  # a real state (a brand new repo closing its first session), not a missing
  # ref: the catalog still gets built, the board is empty and says why.
  if ! git rev-parse --verify -q HEAD >/dev/null 2>&1 && [ -z "$MAIN" ]; then
    if [ -z "$(git for-each-ref --count=1 refs/heads refs/remotes)" ]; then
      MAIN=""; MAIN_SHORT=""; REPO_UNBORN=yes
      return 0
    fi
  fi
  REPO_UNBORN=no
  if [ -z "$MAIN" ]; then
    if git show-ref --verify -q refs/remotes/origin/main; then
      MAIN=origin/main
    elif MAIN="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$MAIN" ]; then
      : # origin/HEAD told us the default branch
    else
      die "integration branch not found: expected refs/remotes/origin/main.
  Run 'git fetch origin' first, or name it explicitly:
    RELEVIO_MAIN=origin/master  (a remote whose default branch is not 'main')
    RELEVIO_MAIN=main           (a repo with no remote at all)
  or pass --main <ref>."
    fi
  fi
  git rev-parse --verify -q "$MAIN^{commit}" >/dev/null \
    || die "integration branch '$MAIN' does not resolve to a commit"
  MAIN_SHORT="${MAIN#origin/}"
}

# --- finding the handoff files ---------------------------------------------
# The union of two sources, because a handoff has two lives:
#   1. git history across ALL refs, so a handoff committed on someone else's
#      unmerged branch is catalogued even though it is not in this worktree;
#   2. the working tree, because /handoff regenerates the index BEFORE it
#      commits, so the file it just wrote exists nowhere else yet.
list_handoffs() {
  {
    git log --all --diff-filter=A --name-only --format='' -- 'docs/handoff/*.md' 2>/dev/null
    ( cd "$TOP" && ls docs/handoff/*.md 2>/dev/null )
  } | grep -E '^docs/handoff/[0-9]{4}-[0-9]{2}-[0-9]{2}_[^/]+\.md$' | sort -u || true
  # `|| true`: a project with no handoffs yet is not an error, but grep exits
  # 1 on no match and the callers run under `set -o pipefail`.
}

# Print the content of a handoff path. The working tree wins (it is the most
# recent truth); otherwise the newest commit that still carries the file is
# used. Addressing the blob by commit hash rather than by ref sidesteps the
# refs/heads/x vs refs/remotes/origin/x duplication entirely: both reach the
# same commit, and the hash is the same from either side.
read_handoff() {
  local p="$1" c
  if [ -f "$TOP/$p" ]; then cat "$TOP/$p"; return 0; fi
  # Newest first, and take the first commit that still HAS the blob: the
  # newest commit touching the path may be the one that deleted or renamed it.
  for c in $(git log --all --format=%H -- "$p" 2>/dev/null); do
    if git cat-file -e "$c:$p" 2>/dev/null; then
      git show "$c:$p"
      return 0
    fi
  done
  die "$p: listed in history but no commit still carries it"
}

# --- the header parser ------------------------------------------------------
# Reads a handoff on stdin, prints ONE tab-separated record on stdout:
#   path  date  session  dev  branch  areas  commits  topics  summary  resume
# Exit 2 with "ERROR: <path>: <field>: <reason>" on stderr otherwise.
parse_header() {
  local label="$1" rec date base branch
  rec="$(awk -v F="$label" '
    function fail(m) { printf("ERROR: %s: %s\n", F, m) > "/dev/stderr"; failed = 1; exit 2 }
    BEGIN { n = split("'"$RELEVIO_FIELDS"'", want, " ") }
    /^[ \t]*$/ { done = 1; exit }
    {
      if (NR > 20) fail("header block not terminated by a blank line within 20 lines")
      line = $0
      sub(/[ \t]+$/, "", line)        # trailing whitespace carries no meaning
      if (line !~ /^[A-Za-z]+: .+$/)
        fail("line " NR " is not \"Key: value\": " line)
      k = line; sub(/:.*/, "", k)
      v = line; sub(/^[A-Za-z]+: /, "", v)
      if (v ~ /^[ \t]/) fail(k ": value starts with whitespace (one space after the colon, and no wrapped lines)")
      if (v ~ /\t/)     fail(k ": value contains a tab")
      if (v ~ /\|/)     fail(k ": value contains \"|\", which would break the index table")
      if (k in seen)    fail(k ": duplicated")
      seen[k] = 1; val[k] = v
    }
    END {
      if (failed) exit 2
      if (!done) fail("header block not terminated by a blank line")
      for (i = 1; i <= n; i++)
        if (!(want[i] in seen)) {
          if (want[i] == "Areas")
            fail("missing field Areas: this header predates relevio v0.22. Run relevio-migrate.sh to convert it (it derives Areas from the commit range).")
          fail("missing field " want[i])
        }
      if (failed) exit 2
      for (k in seen) {
        ok = 0
        for (i = 1; i <= n; i++) if (want[i] == k) ok = 1
        if (!ok) fail(k ": unknown header field (allowed: '"$RELEVIO_FIELDS"')")
      }
      if (failed) exit 2
      if (val["Date"] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
        fail("Date: \"" val["Date"] "\" is not YYYY-MM-DD")
      if (val["Branch"] ~ /^(origin|refs)\//)
        fail("Branch: \"" val["Branch"] "\" must be a bare branch name, not a ref path")
      if (val["Branch"] ~ /[ ()]/)
        fail("Branch: \"" val["Branch"] "\" must be a bare branch name; move the explanation into the body. A header written before relevio v0.22 is converted by relevio-migrate.sh.")
      if (val["Commits"] != "none") {
        if (val["Commits"] !~ /^[0-9a-f]+\.\.[0-9a-f]+$/)
          fail("Commits: \"" val["Commits"] "\" must be <first>..<last> with bare hashes, or exactly \"none\" (a suffix such as \"(10 commits)\" is the pre-v0.22 form: run relevio-migrate.sh)")
        i = index(val["Commits"], "..")
        a = substr(val["Commits"], 1, i - 1); b = substr(val["Commits"], i + 2)
        if (length(a) < 7 || length(a) > 40 || length(b) < 7 || length(b) > 40)
          fail("Commits: hashes must be 7 to 40 hex characters")
      }
      if (val["Areas"] != "none") {
        m = split(val["Areas"], items, ",")
        for (j = 1; j <= m; j++) {
          it = items[j]; sub(/^[ \t]+/, "", it); sub(/[ \t]+$/, "", it)
          if (it == "") fail("Areas: empty item (a stray comma?)")
          if (it ~ /^\//) fail("Areas: \"" it "\" must be a path relative to the repository root")
          if (it ~ /[^A-Za-z0-9._@+\/-]/) fail("Areas: \"" it "\" has characters outside [A-Za-z0-9._@+/-]")
        }
      }
      if (failed) exit 2
      printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", F, val["Date"], val["Session"],
             val["Dev"], val["Branch"], val["Areas"], val["Commits"], val["Topics"],
             val["Summary"], val["Resume"])
    }')" || return 2
  [ -n "$rec" ] || return 2

  # Two checks awk cannot make on its own.
  date="$(printf '%s' "$rec" | cut -f2)"
  branch="$(printf '%s' "$rec" | cut -f5)"
  base="${label##*/}"
  case "$base" in
    "$date"_*) : ;;
    *) echo "ERROR: $label: Date: \"$date\" disagrees with the filename (the catalog is ordered by filename, so they must match)" >&2; return 2 ;;
  esac
  git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || { echo "ERROR: $label: Branch: \"$branch\" is not a valid git branch name" >&2; return 2; }
  printf '%s\n' "$rec"
}

# --- the catalog ------------------------------------------------------------
# CATALOG holds one tab-separated record per handoff, ordered by filename
# (which starts with the date, so it is chronological). Any parse failure
# aborts the whole load: a partial catalog would silently drop a session.
load_catalog() {
  local paths p rec content
  paths="$(list_handoffs)"
  CATALOG=""
  CATALOG_COUNT=0
  [ -n "$paths" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Read first, parse second: chaining them in a pipe would run the parser
    # on empty input after a read failure and print a second, bogus error.
    content="$(read_handoff "$p")" || exit 2
    rec="$(printf '%s\n' "$content" | parse_header "$p")" || exit 2
    CATALOG="${CATALOG}${rec}
"
    CATALOG_COUNT=$((CATALOG_COUNT + 1))
  done <<EOF
$paths
EOF
}

# Field n of a catalog record: 1 path, 2 date, 3 session, 4 dev, 5 branch,
# 6 areas, 7 commits, 8 topics, 9 summary, 10 resume.
fld() { printf '%s' "$1" | cut -f"$2"; }

# --- branches ---------------------------------------------------------------
# The ref to measure a branch by. The remote-tracking ref wins when it exists,
# because that is the branch the rest of the team can actually see; a
# local-only branch still counts as a lane (flagged as such), and a branch
# that exists nowhere is gone.
branch_tip() {
  if git show-ref --verify -q "refs/remotes/origin/$1"; then echo "origin/$1"; return 0; fi
  if git show-ref --verify -q "refs/heads/$1"; then echo "$1"; return 0; fi
  echo ""
}
branch_is_local_only() {
  ! git show-ref --verify -q "refs/remotes/origin/$1" && git show-ref --verify -q "refs/heads/$1"
}

# `Commits: a..b` names an INCLUSIVE range: the session's first commit is `a`.
# git's `a..b` excludes `a`, so every lookup resolves it as `a^..b` (or just
# `b` when `a` is a root commit). Prints nothing when the hashes no longer
# resolve, which happens after a rebase or a squash merge.
range_of() {
  local c="$1" first last
  [ "$c" = "none" ] && return 0
  first="${c%%..*}"; last="${c##*..}"
  git rev-parse --verify -q "$first^{commit}" >/dev/null 2>&1 || return 0
  git rev-parse --verify -q "$last^{commit}"  >/dev/null 2>&1 || return 0
  if git rev-parse --verify -q "$first^{commit}^" >/dev/null 2>&1; then
    echo "$first^..$last"
  else
    echo "$last"
  fi
}

# The distinct branches in the catalog, minus the integration branch itself.
catalog_branches() {
  printf '%s' "$CATALOG" | awk -F'\t' -v m="$MAIN_SHORT" '$5 != "" && $5 != m { print $5 }' | sort -u
}

# One tab-separated board row per ACTIVE lane:
#   branch  devs  last_date  last_file  areas  ahead  note
# A lane is active when its branch still exists and is not an ancestor of the
# integration branch. Merged and deleted branches drop off by design: the
# board answers "what is open right now", the catalog keeps the history.
board_rows() {
  local b tip ahead devs areas last_date last_file note rows=""
  [ "$REPO_UNBORN" = yes ] && return 0
  for b in $(catalog_branches); do
    tip="$(branch_tip "$b")"
    [ -n "$tip" ] || continue
    git merge-base --is-ancestor "$tip" "$MAIN" 2>/dev/null && continue
    ahead="$(git rev-list --count "$MAIN..$tip" 2>/dev/null || echo '?')"
    devs="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b { print $4 }' | sort -u | paste -sd, - | sed 's/,/, /g')"
    areas="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b && $6 != "none" { print $6 }' \
      | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u | paste -sd, - | sed 's/,/, /g')"
    [ -n "$areas" ] || areas="none"
    # The board is meant to be scanned. A session that touched thirty paths
    # would make its row unreadable, so the row shows the first few and says
    # how many it left out; the catalog below still carries the full list.
    areas="$(printf '%s' "$areas" | awk -F', ' '{
      if (NF <= 6) { print; next }
      out = $1
      for (i = 2; i <= 6; i++) out = out ", " $i
      printf("%s, +%d more\n", out, NF - 6)
    }')"
    last_date="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b { d = $2 } END { print d }')"
    last_file="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b { p = $1 } END { sub(/.*\//, "", p); print p }')"
    note=""
    branch_is_local_only "$b" && note="local only"
    rows="${rows}${b}	${devs}	${last_date}	${last_file}	${areas}	${ahead}	${note}
"
  done
  # Most recent lane first: the board is read top-down.
  printf '%s' "$rows" | grep -v '^$' | sort -t'	' -k3,3r -k1,1 || true
}
