#!/usr/bin/env bash
# relevio: an encrypted archive of every Claude Code conversation on this
# machine, so a session Claude Code deleted can be put back and resumed.
#
# Each session is compressed and encrypted with age to two keys: a main key,
# itself protected by a passphrase, and a recovery key that only you keep.
# Archiving needs neither: it encrypts to their public halves, so the hooks
# that archive in the background never hold a secret. Anything that needs a
# secret (setup, restore, keys) runs only in your own terminal.
#
# The archive lives in ~/.relevio (or $RELEVIO_HOME), outside every git
# repository. Lose both the passphrase and the recovery key and the archive is
# gone: nobody, relevio included, can open it.
#
# Usage: relevio-archive.sh <command>
#   setup     create the keys (your terminal only: asks for a passphrase)
#   status    is archiving set up, on and healthy; exit 1 when it is not
#   off       stop archiving new sessions (what is archived stays)
#   on        start again after off
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-handoffs-lib.sh"
umask 077

ARCHIVE_FORMAT=1
RH="${RELEVIO_HOME:-$HOME/.relevio}"
CC_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- The archive's home -------------------------------------------------------
# Refused when it could leak or be swapped: a symlink can point the archive
# anywhere, a directory owned by someone else can be read or replaced by them,
# and an archive inside a git work tree is one `git add -A` away from a commit.
check_home() {
  local d
  if [ -L "$RH" ]; then die "$RH is a symbolic link. The archive must be a real directory you own: move the link away and rerun."; fi
  if [ -e "$RH" ] && { [ ! -d "$RH" ] || [ ! -O "$RH" ]; }; then
    die "$RH exists but is not a directory owned by you. Move it away and rerun."
  fi
  d="$RH"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$RH is inside a git work tree ($(git -C "$d" rev-parse --show-toplevel)). An archive of conversations must never be committable: set RELEVIO_HOME to a directory outside every repository."
  fi
}

# --- The test gate -------------------------------------------------------------
# age reads a passphrase only from a terminal, so automated tests cannot run a
# real setup. RELEVIO_TEST_INSECURE_KEYS=1 stores the main key unprotected
# instead, and is honoured ONLY for a throwaway home: never the real one.
test_gate() {
  [ "${RELEVIO_TEST_INSECURE_KEYS:-}" = 1 ] || return 1
  if [ -z "${RELEVIO_HOME:-}" ] || [ "$RH" = "$HOME/.relevio" ]; then
    die "RELEVIO_TEST_INSECURE_KEYS is for tests only, and only with RELEVIO_HOME pointing at a throwaway directory. Unset it."
  fi
  return 0
}

require_tty() {
  test_gate && return 0
  [ -t 0 ] && [ -t 1 ] || die "this command asks for a secret, so it runs only in your own terminal, never through an agent or a pipe: a secret typed there would be stored in a plaintext transcript. Open a terminal and run it yourself."
}

# --- Dependencies, recorded at setup -------------------------------------------
# Hooks started by a desktop app run with a minimal PATH, so setup records
# absolute paths and every later run uses those.
sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s\n' "$(command -v sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then printf '%s\n' "$(command -v shasum) -a 256"
  else return 1; fi
}
find_deps() {
  local t missing=""
  for t in age age-keygen jq tar gzip; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  sha_tool >/dev/null || missing="$missing sha256sum"
  [ -z "$missing" ] || die "missing:$missing. On Ubuntu: sudo apt install age jq (tar, gzip and sha256sum come with the system)."
}
config_get() { [ -r "$RH/config" ] || return 0; sed -n "s/^$1=//p" "$RH/config" | head -1; }
load_config() {
  [ -r "$RH/config" ] || die "$RH/config is missing: run setup first."
  [ "$(config_get format)" = "$ARCHIVE_FORMAT" ] || die "$RH/config is format '$(relevio_safe "$(config_get format)")', and this relevio reads format $ARCHIVE_FORMAT. Update relevio."
  AGE="$(config_get age)"; AGE_KEYGEN="$(config_get age_keygen)"
  local t
  for t in "$AGE" "$AGE_KEYGEN"; do
    [ -n "$t" ] && [ -x "$t" ] || die "age is missing at '$(relevio_safe "$t")': install it (sudo apt install age) or rerun setup."
  done
}

is_set_up() { [ -s "$RH/keys/recipients.txt" ]; }

# --- setup -----------------------------------------------------------------------
cmd_setup() {
  local main main_pub rec rec_pub rec_secret entered tries=0 tmp n
  check_home
  require_tty
  is_set_up && die "the archive is already set up in $RH (status shows it)."
  find_deps
  mkdir -p "$RH/keys" "$RH/archive"
  chmod 700 "$RH" "$RH/keys" "$RH/archive"
  AGE="$(command -v age)"; AGE_KEYGEN="$(command -v age-keygen)"
  cat <<EOF

relevio archive setup
=====================
relevio will keep an encrypted copy of every Claude Code conversation on this
machine, in $RH. Archiving runs by itself and needs no passphrase.
Opening the archive (restore) needs ONE of two keys:

  1. your PASSPHRASE, which protects the main key. age asks for it twice now.
     An empty passphrase makes age invent one and print it: write that down.
  2. a RECOVERY KEY, shown once below, for when the passphrase is lost.

relevio cannot recover anything. Lose both and the archive is gone for good.
Never paste the recovery key into Claude or any chat: it would be stored in a
plaintext transcript. Clear this terminal's scrollback when you are done.

EOF
  # The main key: generated and encrypted in memory, never on disk in clear.
  main="$("$AGE_KEYGEN" 2>/dev/null)"
  main_pub="$(printf '%s\n' "$main" | "$AGE_KEYGEN" -y)"
  if test_gate; then
    printf '%s\n' "$main" > "$RH/keys/main.key"
  else
    printf '%s\n' "$main" | "$AGE" -p -o "$RH/keys/main.age.tmp" || { rm -rf "$RH/keys"; die "the passphrase step did not finish; nothing was set up."; }
    mv "$RH/keys/main.age.tmp" "$RH/keys/main.age"
  fi
  unset main
  # The recovery key: shown once, never stored. Tests may hand one in.
  if test_gate && [ -n "${RELEVIO_TEST_RECOVERY_IDENTITY:-}" ]; then
    rec="$(cat "$RELEVIO_TEST_RECOVERY_IDENTITY")"
  else
    rec="$("$AGE_KEYGEN" 2>/dev/null)"
  fi
  rec_pub="$(printf '%s\n' "$rec" | "$AGE_KEYGEN" -y)"
  rec_secret="$(printf '%s\n' "$rec" | grep '^AGE-SECRET-KEY-1')"
  unset rec
  cat <<EOF
YOUR RECOVERY KEY (save it now in a password manager or on paper):

  $rec_secret

EOF
  unset rec_secret
  while :; do
    tries=$((tries + 1))
    printf 'Type the recovery key back to confirm you saved it: '
    if test_gate; then IFS= read -r entered || entered=""; else IFS= read -rs entered < /dev/tty || entered=""; echo; fi
    entered="$(printf '%s' "$entered" | tr -d ' \t' | tr '[:lower:]' '[:upper:]')"
    [ "$(printf '%s\n' "$entered" | "$AGE_KEYGEN" -y 2>/dev/null)" = "$rec_pub" ] && break
    if [ "$tries" -ge 3 ]; then
      unset entered; rm -rf "$RH/keys"
      die "the recovery key did not match three times. Nothing was set up; run setup again."
    fi
    echo "That does not match. Try again ($tries of 3)."
  done
  unset entered
  tmp="$RH/keys/recipients.txt.tmp"
  {
    echo "# relevio recipients, format $ARCHIVE_FORMAT. Every archive is encrypted to every key below."
    echo "# main (passphrase-protected key, created $(date -u +%Y-%m-%d))"
    echo "$main_pub"
    echo "# recovery (its secret half is NOT stored anywhere by relevio)"
    echo "$rec_pub"
  } > "$tmp"
  mv "$tmp" "$RH/keys/recipients.txt"
  printf 'relevio-canary 1\n' | "$AGE" -e -R "$RH/keys/recipients.txt" -o "$RH/keys/canary.age"
  {
    echo "format=$ARCHIVE_FORMAT"
    echo "age=$AGE"
    echo "age_keygen=$AGE_KEYGEN"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RH/config.tmp"
  mv "$RH/config.tmp" "$RH/config"
  # Prove the way back works before anything is archived with these keys.
  echo "Checking the passphrase opens the archive (age asks once more):"
  if ! canary_opens_with_main; then
    rm -rf "$RH/keys" "$RH/config"
    die "the main key could not open a test file, so nothing was set up. Run setup again."
  fi
  n="$(find "$CC_DIR/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null | grep -c . || true)"
  cat <<EOF

The archive is set up in $RH.
New sessions are archived as they end. To archive the $n conversations already
on this machine now, run:

  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-archive.sh" backfill
EOF
}

# Decrypts the canary with the main key: from the passphrase, or from the
# unprotected test key under the gate.
canary_opens_with_main() {
  local id
  if [ -r "$RH/keys/main.key" ] && test_gate; then
    id="$(cat "$RH/keys/main.key")"
  else
    id="$("$AGE" -d "$RH/keys/main.age")" || return 1
  fi
  [ "$("$AGE" -d -i <(printf '%s\n' "$id") "$RH/keys/canary.age" 2>/dev/null)" = "relevio-canary 1" ]
}

# --- status ------------------------------------------------------------------------
human_bytes() { awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }
fmt_time() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$1"; }
status_field() { [ -r "$RH/status" ] || return 0; sed -n "s/^$1 //p" "$RH/status" | head -1; }
cmd_status() {
  local healthy=yes state at pid age_s keys k
  check_home
  if ! is_set_up; then
    echo "archive: NOT SET UP. Conversations are not being archived."
    echo "  Set it up in your own terminal: bash \"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-archive.sh\" setup"
    [ -e "$RH/off" ] && echo "  (turned off: the start-of-session notice is silenced)"
    exit 1
  fi
  load_config
  if [ -e "$RH/off" ]; then echo "archive: OFF (nothing new is archived; run 'on' to resume)"; else echo "archive: on, in $RH"; fi
  [ -r "$RH/keys/main.key" ] && { echo "  INSECURE TEST KEYS: the main key is stored unprotected (test gate)"; healthy=no; }
  keys="$(grep -c '^age1' "$RH/keys/recipients.txt" || true)"
  echo "  keys: $keys recipient(s):$(grep '^age1' "$RH/keys/recipients.txt" | cut -c1-12 | sed 's/^/ /;s/$/.../' | tr -d '\n')"
  state="$(status_field state)"; at="$(status_field at)"; pid="$(status_field pid)"
  if [ -z "$state" ]; then
    echo "  last run: none yet"
  else
    case "$state" in
      running) if kill -0 "$pid" 2>/dev/null; then echo "  last run: running now (pid $pid)"; else echo "  last run: INTERRUPTED (started $(fmt_time "$at"), process gone)"; healthy=no; fi ;;
      fail) echo "  last run: FAILING since $(fmt_time "$at"): $(relevio_safe "$(status_field message)")"; healthy=no ;;
      *) age_s=$(( $(date +%s) - ${at:-0} ))
         echo "  last run: ok, $(fmt_time "$at"); $(relevio_safe "$(status_field counts)")"
         if [ ! -e "$RH/off" ] && [ "$age_s" -gt $((7 * 86400)) ]; then echo "  STALE: no successful run in over 7 days"; healthy=no; fi ;;
    esac
  fi
  if [ -r "$RH/index.tsv" ]; then
    local n b sup del
    read -r n b sup del < <(awk -F'\t' 'NR > 1 { c[$1]++; if ($1 != "superseded") b += $11 }
      END { printf "%d %d %d %d\n", c["active"] + c["deleted-in-claude"], b, c["superseded"], c["deleted-in-claude"] }' "$RH/index.tsv")
    echo "  archived: $n session(s), $(human_bytes "$b") encrypted$([ "$sup" -gt 0 ] && echo "; $sup older generation(s)")$([ "$del" -gt 0 ] && echo "; $del deleted in Claude, kept")"
  else
    echo "  archived: nothing yet"
  fi
  [ -s "$RH/forgotten.tsv" ] && echo "  forgotten: $(grep -c . "$RH/forgotten.tsv") session(s), never archived again"
  if [ -e "$CC_DIR/settings.json" ]; then
    k="$(jq -r 'if type == "object" and has("cleanupPeriodDays") then (.cleanupPeriodDays | tojson) else "unset (30 days)" end' "$CC_DIR/settings.json" 2>/dev/null || echo "unreadable")"
  else
    k="unset (30 days)"
  fi
  echo "  Claude Code keeps conversations: cleanupPeriodDays $(relevio_safe "$k") in $CC_DIR/settings.json"
  echo "  Claude Code's own conversations: $(human_bytes "$(du -sk "$CC_DIR/projects" 2>/dev/null | awk '{ print $1 * 1024 }')") in $CC_DIR/projects"
  [ "$healthy" = yes ] || exit 1
}

# --- off / on ------------------------------------------------------------------------
cmd_off() {
  check_home; mkdir -p "$RH"; chmod 700 "$RH"; : > "$RH/off"
  echo "archive: OFF. Nothing new is archived; what is archived stays. Turn it back on with 'on'."
}
cmd_on() {
  check_home; rm -f "$RH/off"
  if is_set_up; then echo "archive: on."; else echo "archive: on, but NOT SET UP yet: run setup in your own terminal."; fi
}

case "${1:-}" in
  setup) cmd_setup ;;
  status) cmd_status ;;
  off) cmd_off ;;
  on) cmd_on ;;
  -h|--help|help|"") relevio_usage "${BASH_SOURCE[0]}"; [ -n "${1:-}" ] || exit 2 ;;
  *) die "unknown command '$(relevio_safe "$1")'. Run with --help for the list." ;;
esac
