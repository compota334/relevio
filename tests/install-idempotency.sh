#!/usr/bin/env bash
# relevio: regression guard for install.sh idempotency.
#
# The property asserted here is idempotency itself, not any particular
# formatting detail: running the installer twice in a row must leave the second
# run with an empty git diff. It exists because CLAUDE.md once drifted by one
# blank line on EVERY re-run (the separator emitted by one run survived the next
# run's strip, which then added its own), so `--update` always reported a change
# even when nothing had changed. A diff that is always dirty is a diff people
# stop reading, which is corrosive for a tool whose whole promise is that you
# can trust what it does and does not touch.
#
# Usage:  bash tests/install-idempotency.sh
# Exit 0 = all cases pass. Exit 1 = a regression.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO/install.sh"
FAILURES=0

pass() { echo "  PASS  $1"; }
failed() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
check() { [ "$2" = "$3" ] && pass "$1" || failed "$1 (expected '$3', got '$2')"; }

# A throwaway git repo with the given CLAUDE.md content (empty = no CLAUDE.md).
fixture() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q .
  git -C "$dir" config user.email test@relevio.local
  git -C "$dir" config user.name relevio-test
  git -C "$dir" config commit.gpgsign false
  [ -n "${1:-}" ] && printf '%s' "$1" > "$dir/CLAUDE.md"
  echo "$dir"
}

# Is the working tree clean for the given path?
diff_is_empty() { [ -z "$(git -C "$1" diff -- "$2")" ] && echo empty || echo dirty; }

echo "relevio install idempotency"

# --- Case 1: repeated --update leaves a clean diff --------------------------
d="$(fixture '# My project

- A rule of my own.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
# Settle first: the very first --update may legitimately relocate the relevio
# block to the end of the file. Idempotency is about every run after that.
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm settled
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "second --update leaves no diff" "$(diff_is_empty "$d" CLAUDE.md)" "empty"
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "further --update runs leave no diff" "$(diff_is_empty "$d" CLAUDE.md)" "empty"
check "exactly one relevio block" \
  "$(grep -cF '<!-- relevio:start -->' "$d/CLAUDE.md")" "1"
check "the user's own rule survived" \
  "$(grep -c 'A rule of my own' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 2: user text on BOTH sides of the block ---------------------------
d="$(fixture '# My project

- Rule above.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
printf '\n## Rules below\n- Never deploy on a Friday.\n' >> "$d/CLAUDE.md"
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)   # settle
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm settled
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "text on both sides: repeated --update is stable" \
  "$(diff_is_empty "$d" CLAUDE.md)" "empty"
check "text above the block survived" "$(grep -c 'Rule above' "$d/CLAUDE.md")" "1"
check "text below the block survived" \
  "$(grep -c 'Never deploy on a Friday' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 3: a CLAUDE.md that ends in a pile of blank lines -----------------
# The trailing-blank trim must converge instead of preserving the pile forever.
d="$(fixture '# My project
- A rule.



')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)   # settle
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm settled
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "trailing blank lines: repeated --update is stable" \
  "$(diff_is_empty "$d" CLAUDE.md)" "empty"
check "the user's rule survived the trim" "$(grep -c '^- A rule\.$' "$d/CLAUDE.md")" "1"
rm -rf "$d"

# --- Case 4: the hook and the commands are idempotent too -------------------
d="$(fixture '# My project
- A rule.
')"
(cd "$d" && bash "$INSTALLER" >/dev/null 2>&1)
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm installed
(cd "$d" && bash "$INSTALLER" --update >/dev/null 2>&1)
check "hook and commands leave no diff on re-update" \
  "$(diff_is_empty "$d" .claude)" "empty"
rm -rf "$d"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES case(s) FAILED"
exit 1
