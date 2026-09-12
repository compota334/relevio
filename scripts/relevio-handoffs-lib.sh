#!/usr/bin/env bash
# relevio: shared library for the handoff scripts (relevio-index.sh,
# relevio-trace.sh, relevio-areas.sh, relevio-migrate.sh). Source it, do not
# run it.
#
# Everything here is POSIX awk + bash 3.2 + git. No jq, no GNU-only flags,
# no `tac`, no `sort -V`, no `sed -i`, no `readlink -f`: the scripts run on
# Linux and on macOS with its stock bash 3.2 and BSD awk.
#
# The design rule is fail-loud: a malformed handoff header aborts the whole
# run naming the file and the field. Nothing is guessed, nothing is skipped
# silently, and no output file is touched until every header has parsed.

[ "${BASH_SOURCE[0]}" != "${0}" ] || {
  echo "relevio-handoffs-lib.sh is a library: run relevio-index.sh, relevio-trace.sh, relevio-areas.sh or relevio-migrate.sh instead." >&2
  exit 2
}

# The nine header fields, in canonical order. Order is NOT enforced when
# parsing (an agent may reorder without breaking the catalog); this list is
# what the parser requires to be present, what relevio-migrate.sh writes, and
# what the /handoff command documents.
RELEVIO_FIELDS="Session Date Dev Branch Commits Areas Resume Topics Summary"

# Byte ordering everywhere. `sort` collates differently per locale, so without
# this two devs regenerating the same index on the same commits would produce
# two different files and a pointless merge conflict.
export LC_ALL=C

die() { echo "ERROR: $*" >&2; exit 2; }

# The repository root, from anywhere inside it (a worktree included).
relevio_top() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

# Print a script's banner comment as its usage text. Derived from the file, so
# editing a banner can never leave the help truncated or over-long.
relevio_usage() {
  sed -n '2,/^[^#]/p' "$1" | sed -n 's/^# \{0,1\}//p'
}

# Join stdin lines into the catalog's list form, "a, b, c". One definition,
# because the parser splits Areas on the same separator.
join_csv() { paste -sd, - | sed 's/,/, /g'; }

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
  REPO_UNBORN=no
  if [ -z "$MAIN" ] && [ -z "$(git for-each-ref --count=1 refs/heads refs/remotes)" ]; then
    MAIN=""; REPO_UNBORN=yes
    return 0
  fi
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
}

# --- finding the handoff files ---------------------------------------------
# One walk of every ref, resolving BOTH questions at once: which handoff paths
# exist anywhere in history, and which commit to read each of them from.
# --diff-filter=d excludes deletions, so the newest commit listed for a path is
# guaranteed to still carry the blob. Doing this per file instead would mean
# one full ref walk per handoff, which is the common case for a team whose
# handoffs live on each other's branches.
# Sets HANDOFF_REFS to "path<TAB>commit" lines, sorted by path.
scan_handoffs() {
  local worktree
  worktree="$( cd "$TOP" && ls docs/handoff/*.md 2>/dev/null || true )"
  HANDOFF_REFS="$(
    {
      git log --all --format='%H' --name-only --diff-filter=d -- 'docs/handoff/*.md' 2>/dev/null \
        | awk '
            # Commit lines have no slash; path lines do. Newest first, so the
            # first sighting of a path is the commit to read it from.
            NF && $0 !~ /\// { c = $0; next }
            NF && !($0 in seen) { seen[$0] = 1; print $0 "\t" c }'
      # A handoff being written right now exists only in the working tree:
      # /handoff regenerates the index before it commits.
      printf '%s\n' "$worktree" | awk 'NF { print $0 "\t" }'
    } | grep -E '^docs/handoff/[0-9]{4}-[0-9]{2}-[0-9]{2}_[^/]+\.md	' \
      | sort -u -t'	' -k1,1 || true
    # `|| true`: a project with no handoffs yet is not an error, but grep exits
    # 1 on no match and the callers run under `set -o pipefail`.
  )"
}

# --- the header parser ------------------------------------------------------
# Reads a handoff on stdin, prints ONE tab-separated record on stdout:
#   path  date  session  dev  branch  areas  commits  topics  summary  resume
# Exit 2 with "ERROR: <path>: <field>: <reason>" on stderr otherwise.
parse_header() {
  local label="$1" rec date branch
  rec="$(awk -v F="$label" -v fields="$RELEVIO_FIELDS" '
    function fail(m) { printf("ERROR: %s: %s\n", F, m) > "/dev/stderr"; failed = 1; exit 2 }
    BEGIN { n = split(fields, want, " "); for (i = 1; i <= n; i++) allowed[want[i]] = 1 }
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
      # fail() exits; inside END that ends the program, and inside a rule it
      # jumps here, which is what this one guard catches.
      if (failed) exit 2
      if (!done) fail("header block not terminated by a blank line")
      for (i = 1; i <= n; i++)
        if (!(want[i] in seen)) {
          if (want[i] == "Areas")
            fail("missing field Areas: this header predates relevio v0.22. Run relevio-migrate.sh to convert it (it derives Areas from the commit range).")
          fail("missing field " want[i])
        }
      for (k in seen)
        if (!(k in allowed)) fail(k ": unknown header field (allowed: " fields ")")
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
      printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", F, val["Date"], val["Session"],
             val["Dev"], val["Branch"], val["Areas"], val["Commits"], val["Topics"],
             val["Summary"], val["Resume"])
    }')" || return 2
  [ -n "$rec" ] || return 2

  # Two checks awk cannot make on its own.
  IFS='	' read -r _ date _ _ branch _ <<EOF
$rec
EOF
  case "${label##*/}" in
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
  local p c content rec
  scan_handoffs
  CATALOG=""
  CATALOG_COUNT=0
  [ -n "$HANDOFF_REFS" ] || return 0
  while IFS='	' read -r p c; do
    [ -n "$p" ] || continue
    # Read first, parse second: chaining them in a pipe would run the parser
    # on empty input after a read failure and print a second, bogus error.
    if [ -n "$c" ] && [ ! -f "$TOP/$p" ]; then
      content="$(git show "$c:$p")" || exit 2
    else
      content="$(cat "$TOP/$p")" || exit 2
    fi
    rec="$(printf '%s\n' "$content" | parse_header "$p")" || exit 2
    CATALOG="${CATALOG}${rec}
"
    CATALOG_COUNT=$((CATALOG_COUNT + 1))
  done <<EOF
$HANDOFF_REFS
EOF
}

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

# gone | merged | open. The single definition of what an active lane is: the
# board keeps the `open` ones, the trace labels every row with it. Two copies
# of this decision would let the board and the trace disagree about the same
# branch, which is the one thing a board must never do.
branch_state() {
  local tip
  [ "$REPO_UNBORN" = yes ] && { echo gone; return 0; }
  tip="$(branch_tip "$1")"
  [ -n "$tip" ] || { echo gone; return 0; }
  if git merge-base --is-ancestor "$tip" "$MAIN" 2>/dev/null; then echo merged; else echo open; fi
}

# The devs who closed a session on a branch, as "ANA, NICO".
devs_of() {
  printf '%s' "$CATALOG" | awk -F'\t' -v b="$1" '$5 == b { print $4 }' | sort -u | join_csv
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

# The paths a commit range touched, as an Areas value. The single definition of
# that derivation: the /handoff command calls it through relevio-areas.sh
# rather than re-typing the pipeline, so nobody can drop the `^` and silently
# lose the session's own first commit. Returns 1 when the range no longer
# resolves, so the caller can report it instead of inventing a value.
areas_for_range() {
  local range a
  [ "$1" = none ] && { echo none; return 0; }
  range="$(range_of "$1")"
  [ -n "$range" ] || return 1
  a="$(git log --format= --name-only "$range" 2>/dev/null | cut -d/ -f1-2 | sort -u | grep -v '^$' || true)"
  # A session that touched dozens of files makes an unreadable row; those
  # collapse to their top-level directory.
  if [ "$(printf '%s\n' "$a" | grep -c '')" -gt 12 ]; then
    a="$(printf '%s\n' "$a" | cut -d/ -f1 | sort -u)"
  fi
  a="$(printf '%s' "$a" | join_csv)"
  printf '%s\n' "${a:-none}"
}

# The distinct branches in the catalog, minus the integration branch itself.
catalog_branches() {
  printf '%s' "$CATALOG" | awk -F'\t' -v m="${MAIN#origin/}" '$5 != "" && $5 != m { print $5 }' | sort -u
}

# One tab-separated board row per ACTIVE lane:
#   branch  devs  last_date  last_file  areas  ahead  note
# Merged and deleted branches drop off by design: the board answers "what is
# open right now", the catalog keeps the history.
board_rows() {
  local b tip ahead areas last note rows=""
  for b in $(catalog_branches); do
    [ "$(branch_state "$b")" = open ] || continue
    tip="$(branch_tip "$b")"
    ahead="$(git rev-list --count "$MAIN..$tip" 2>/dev/null || echo '?')"
    # One pass for both fields of the branch's last record.
    last="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b { d = $2; p = $1 } END { sub(/.*\//, "", p); print d "\t" p }')"
    # The board is meant to be scanned, so a lane that touched thirty paths
    # shows the first few and says how many it left out; the catalog row below
    # still carries the full list.
    areas="$(printf '%s' "$CATALOG" | awk -F'\t' -v b="$b" '$5 == b && $6 != "none" { print $6 }' \
      | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u \
      | awk 'NR <= 6 { out = (NR == 1 ? $0 : out ", " $0) }
             END { if (NR == 0) print "none"; else print (NR > 6 ? out ", +" NR - 6 " more" : out) }')"
    case "$tip" in origin/*) note="" ;; *) note="local only" ;; esac
    rows="${rows}${b}	$(devs_of "$b")	${last}	${areas}	${ahead}	${note}
"
  done
  # Most recent lane first: the board is read top-down.
  printf '%s' "$rows" | grep -v '^$' | sort -t'	' -k3,3r -k1,1 || true
}
