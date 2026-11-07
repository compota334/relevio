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
#   backfill  archive every conversation already on this machine, now
#   list [q]  what is archived (filter by id prefix, folder or cwd); decrypts nothing
#   restore <id> [--recovery] [--generation <file>] [--folder <f>] [--replace]
#             put an archived session back so claude --resume finds it
#             (your terminal only)
#   keys check [--recovery] | passphrase | reset
#             test a key, change the passphrase, or start over with the
#             recovery key when the passphrase is lost (your terminal only)
#   forget <id>  remove a session from the archive for good (your terminal only)
#   off       stop archiving new sessions (what is archived stays)
#   on        start again after off
#   sync      what the hooks run: --session <id> --transcript <path> [--wait-stable],
#             --repo <dir>, --folder <project folder name>, --all, or
#             --from-start --project <dir> --transcript <path>; --detach runs it
#             in the background
#   notice    the one-line session-start notice, or nothing
#   session-start --project <dir> --transcript <path> [--no-notice]
#             what the session-start hook runs: the notice, then the sweep
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

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-archive.sh"
utc_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# --- Keys -----------------------------------------------------------------------
# A key typed by the user: hidden, from the terminal (from stdin under the test
# gate), and normalized as age keys are written (no spaces, upper case).
read_key_line() {
  local k
  if test_gate; then IFS= read -r k || k=""; else IFS= read -rs k < /dev/tty || k=""; echo >&2; fi
  printf '%s' "$k" | tr -d ' \t' | tr '[:lower:]' '[:upper:]'
}
# protect_main_key <identity> <stem>: <stem>.age, encrypted with a passphrase
# age asks for; under the test gate, <stem>.key in clear.
protect_main_key() {
  if test_gate; then printf '%s\n' "$1" > "$2.key"; return 0; fi
  printf '%s\n' "$1" | "$AGE" -p -o "$2.age.tmp" && mv "$2.age.tmp" "$2.age"
}
write_recipients() {  # <main public key> <recovery public key> <file>
  { echo "# relevio recipients, format $ARCHIVE_FORMAT. Every archive is encrypted to every key below."
    echo "# main (passphrase-protected key, $(date -u +%Y-%m-%d))"; echo "$1"
    echo "# recovery (its secret half is NOT stored anywhere by relevio)"; echo "$2"; } > "$3.tmp"
  mv "$3.tmp" "$3"
}
write_canary() { printf 'relevio-canary 1\n' | "$AGE" -e -R "$RH/keys/recipients.txt" -o "$RH/keys/canary.age"; }
canary_opens() { [ "$("$AGE" -d -i <(printf '%s\n' "$1") "$RH/keys/canary.age" 2>/dev/null)" = "relevio-canary 1" ]; }

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
  local main main_pub rec rec_pub rec_secret entered tries=0 n
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
  protect_main_key "$main" "$RH/keys/main" || { rm -rf "$RH/keys"; die "the passphrase step did not finish; nothing was set up."; }
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
    entered="$(read_key_line)"
    [ "$(printf '%s\n' "$entered" | "$AGE_KEYGEN" -y 2>/dev/null)" = "$rec_pub" ] && break
    if [ "$tries" -ge 3 ]; then
      unset entered; rm -rf "$RH/keys"
      die "the recovery key did not match three times. Nothing was set up; run setup again."
    fi
    echo "That does not match. Try again ($tries of 3)."
  done
  unset entered
  write_recipients "$main_pub" "$rec_pub" "$RH/keys/recipients.txt"
  write_canary
  {
    echo "format=$ARCHIVE_FORMAT"
    echo "age=$AGE"
    echo "age_keygen=$AGE_KEYGEN"
    echo "created=$(utc_iso)"
  } > "$RH/config.tmp"
  mv "$RH/config.tmp" "$RH/config"
  # Prove the way back works before anything is archived with these keys.
  echo "Checking the passphrase opens the archive (age asks once more):"
  if ! { main="$(read_main_identity)" && canary_opens "$main"; }; then
    rm -rf "$RH/keys" "$RH/config"
    die "the main key could not open a test file, so nothing was set up. Run setup again."
  fi
  n="$(find "$CC_DIR/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null | grep -c . || true)"
  cat <<EOF

The archive is set up in $RH.
New sessions are archived as they end. To archive the $n conversations already
on this machine now, run:

  bash "$SELF" backfill
EOF
  unset main
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
    echo "  Set it up in your own terminal: bash \"$SELF\" setup"
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
    k="$(jq -r 'if type == "object" and has("cleanupPeriodDays") then (.cleanupPeriodDays | tojson) else "" end' "$CC_DIR/settings.json" 2>/dev/null || echo "?unreadable")"
  fi
  case "$k" in "") k="unset (30 days)" ;; "?unreadable") k="unreadable" ;; *) k="$(relevio_safe "$k")" ;; esac
  echo "  Claude Code keeps conversations: cleanupPeriodDays $k in $CC_DIR/settings.json"
  echo "  Claude Code's own conversations: $(human_bytes "$(du -sk "$CC_DIR/projects" 2>/dev/null | awk '{ print $1 * 1024 }')") in $CC_DIR/projects"
  [ "$healthy" = yes ] || exit 1
}

# --- Archiving ------------------------------------------------------------------
# Every path below goes through $RH and $PROJECTS, so the tests can point both
# at throwaway directories. The transcript content is only ever read by tar and
# by the sha256 tool: it is never echoed, logged or written unencrypted.
PROJECTS="$CC_DIR/projects"
INDEX="$RH/index.tsv"
INDEX_HEADER="#relevio-archive-index	$ARCHIVE_FORMAT"
SESSION_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
TAB="$(printf '\t')"
# Timing, overridable only under the test gate: how long a transcript must sit
# still before a sweep takes it (minutes), and how long a run waits for the lock.
# Every test knob is read here and nowhere else.
QUIET_MIN=2; LOCK_WAIT=120; STABLE_WAIT=1; TEST_FREE_KB=""; TEST_FAIL_AFTER=""
if test_gate; then
  QUIET_MIN="${RELEVIO_TEST_QUIET_MIN:-$QUIET_MIN}"
  LOCK_WAIT="${RELEVIO_TEST_LOCK_WAIT:-$LOCK_WAIT}"
  STABLE_WAIT="${RELEVIO_TEST_STABLE_WAIT:-$STABLE_WAIT}"
  TEST_FREE_KB="${RELEVIO_TEST_FREE_KB:-}"
  TEST_FAIL_AFTER="${RELEVIO_TEST_FAIL_AFTER:-}"
fi

log() { printf '%s %s\n' "$(utc_iso)" "$*" >> "$RH/log"; }
cap_log() {
  [ -f "$RH/log" ] || return 0
  tail -n 1000 "$RH/log" > "$RH/log.tmp" && mv "$RH/log.tmp" "$RH/log"
}
# "<bytes> <mtime>" of a file, GNU stat or BSD stat.
file_stat() { stat -c '%s %Y' "$1" 2>/dev/null || stat -f '%z %m' "$1" 2>/dev/null; }
sha_of() { $SHA | awk '{ print $1 }'; }
# Never an empty field: bash read collapses empty tab-separated fields.
field() { local v; v="$(printf '%s' "$1" | tr '\t\n' '??')"; printf '%s' "${v:-$RELEVIO_NONE}"; }

# --- status file -------------------------------------------------------------------
N_ARCHIVED=0; N_SKIPPED=0; N_DEFERRED=0; N_FAILED=0; RUN_SCOPE=""; RUN_DONE=0; LAST_ERROR=""
counts() { printf 'archived %d skipped %d deferred %d failed %d' "$N_ARCHIVED" "$N_SKIPPED" "$N_DEFERRED" "$N_FAILED"; }
status_write() {  # $1 state  $2 message
  { echo "state $1"; echo "at $(date +%s)"; echo "pid $$"; echo "scope ${RUN_SCOPE:-$RELEVIO_NONE}"
    echo "counts $(counts)"; echo "message $(printf '%s' "${2:-}" | tr '\n\t' '  ' | cut -c1-200)"; } > "$RH/status.tmp"
  mv "$RH/status.tmp" "$RH/status"
}
# A run that stops before its end (an error, a signal) leaves the status
# saying so, so the next session start can speak for it.
on_exit() {
  local rc=$?
  if [ "$RUN_DONE" != 1 ] && [ -n "$RUN_SCOPE" ] && [ -d "$RH" ]; then
    status_write fail "the run stopped early (exit $rc)${LAST_ERROR:+: $LAST_ERROR}; details in $RH/log"
    log "run $RUN_SCOPE stopped early, exit $rc"
  fi
  release_lock
  cap_log
}

# --- lock --------------------------------------------------------------------------
# mkdir is atomic everywhere (macOS has no flock). A lock whose process is gone
# is stale and retaken once.
LOCKED=0
release_lock() { [ "$LOCKED" = 1 ] && rm -rf "$RH/lock"; LOCKED=0; }
try_lock() {
  if mkdir "$RH/lock" 2>/dev/null; then echo $$ > "$RH/lock/pid"; LOCKED=1; return 0; fi
  local pid; pid="$(cat "$RH/lock/pid" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$RH/lock"; log "took over a stale lock (pid ${pid:-none})"
    if mkdir "$RH/lock" 2>/dev/null; then echo $$ > "$RH/lock/pid"; LOCKED=1; return 0; fi
  fi
  return 1
}
take_lock() {  # $1 quiet|wait
  local waited=0
  try_lock && return 0
  [ "$1" = wait ] || return 1
  while [ "$waited" -lt "$LOCK_WAIT" ]; do
    sleep 2; waited=$((waited + 2)); try_lock && return 0
  done
  return 1
}

# --- index ---------------------------------------------------------------------------
# One line per bundle: state session folder cwd cc_version jsonl_bytes
# jsonl_sha256 jsonl_mtime files bundle bundle_bytes archived_at. State is
# active, deleted-in-claude or superseded (an older generation). Rewritten only
# under the lock, through a temporary file.
index_init() { [ -s "$INDEX" ] || printf '%s\n' "$INDEX_HEADER" > "$INDEX"; }
# The index rows of the current sessions, keyed "<folder>/<id>". I_STATE says
# a row exists; the others are its fields.
declare -A I_STATE I_BYTES I_SHA I_MTIME I_FILES FORGOTTEN FOLDER_CWD F_STAT F_RECENT
index_load() {
  local st id fo cwd ver by sha mt fi _rest
  I_STATE=(); I_BYTES=(); I_SHA=(); I_MTIME=(); I_FILES=()
  [ -s "$INDEX" ] || return 0
  [ "$(head -1 "$INDEX")" = "$INDEX_HEADER" ] || die "$INDEX is not a format $ARCHIVE_FORMAT index (first line: '$(relevio_safe "$(head -1 "$INDEX" | cut -c1-60)")')."
  while IFS="$TAB" read -r st id fo cwd ver by sha mt fi _rest; do
    case "$st" in active|deleted-in-claude) ;; *) continue ;; esac
    I_STATE["$fo/$id"]="$st"; I_BYTES["$fo/$id"]="$by"; I_SHA["$fo/$id"]="$sha"
    I_MTIME["$fo/$id"]="$mt"; I_FILES["$fo/$id"]="$fi"
  done < <(tail -n +2 "$INDEX")
}
index_forget_row() { unset "I_STATE[$1]" "I_BYTES[$1]" "I_SHA[$1]" "I_MTIME[$1]" "I_FILES[$1]"; }
forgotten_load() {
  local id _rest
  FORGOTTEN=()
  [ -r "$RH/forgotten.tsv" ] || return 0
  while IFS="$TAB" read -r id _rest; do [ -n "$id" ] && FORGOTTEN["$id"]=1; done < "$RH/forgotten.tsv"
}
# index_edit <folder> <id> <op> [arg]: op put <line> (replaces the current
# line), state <new state>, mtime <epoch>, supersede <generation bundle name>.
index_edit() {
  local fo="$1" id="$2" op="$3" arg="${4:-}"
  index_init
  FO="$fo" ID="$id" OP="$op" ARG="$arg" awk -F'\t' -v OFS='\t' '
    BEGIN { fo = ENVIRON["FO"]; id = ENVIRON["ID"]; op = ENVIRON["OP"]; arg = ENVIRON["ARG"] }
    NR == 1 { print; next }
    $3 == fo && $2 == id && ($1 == "active" || $1 == "deleted-in-claude") {
      if (op == "put") next
      if (op == "state") $1 = arg
      if (op == "mtime") $8 = arg
      if (op == "supersede") { $1 = "superseded"; $10 = arg }
    }
    { print }
    END { if (op == "put") print arg }' "$INDEX" > "$INDEX.tmp"
  mv "$INDEX.tmp" "$INDEX"
}

# --- which repository a project folder belongs to --------------------------------------
# Claude Code names each folder after an encoding of its cwd that is lossy (and
# hashes long paths), so the cwd is read from a transcript inside it, once per
# folder ever, and cached in folders.tsv.
transcript_cwd() { grep -m1 '"cwd":' "$1" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null || true; }
folders_load() {
  local fo c _rest
  FOLDER_CWD=()
  [ -r "$RH/folders.tsv" ] || return 0
  while IFS="$TAB" read -r fo c _rest; do [ -n "$fo" ] && FOLDER_CWD["$fo"]="$c"; done < "$RH/folders.tsv"
}
folder_cwd() {  # sets FCWD to the folder's cwd, or empty
  local fo="$1" f
  FCWD=""
  if [ -n "${FOLDER_CWD[$fo]+set}" ]; then FCWD="${FOLDER_CWD[$fo]}"; return 0; fi
  for f in "$PROJECTS/$fo"/*.jsonl; do
    [ -r "$f" ] || continue
    FCWD="$(transcript_cwd "$f")"; [ -n "$FCWD" ] && break
  done
  if [ -z "$FCWD" ]; then log "folder $fo: no readable cwd, skipped"; FOLDER_CWD["$fo"]=""; return 0; fi
  FCWD="$(printf '%s' "$FCWD" | tr '\t\n' '??')"
  printf '%s\t%s\t%s\n' "$fo" "$FCWD" "$(date +%s)" >> "$RH/folders.tsv"
  FOLDER_CWD["$fo"]="$FCWD"
}

# --- one folder, one session -------------------------------------------------------------
# folder_scan <folder>: F_STAT[id] is "<bytes> <mtime>" of every session file
# directly in the folder (nothing else there is a session: memory/,
# sessions-index.json, *.desktop-released.json, set-aside copies), and
# F_RECENT[id] marks a session with any file written in the last QUIET_MIN
# minutes. One stat and one find per folder, not per session.
if stat -c %s / >/dev/null 2>&1; then STAT_FMT=(-c '%s %Y %n'); else STAT_FMT=(-f '%z %m %N'); fi
folder_scan() {
  local fo="$1" b m path id rel
  local -a files
  F_STAT=(); F_RECENT=()
  files=("$PROJECTS/$fo"/*.jsonl)
  [ -e "${files[0]}" ] || return 0
  while read -r b m path; do
    id="${path##*/}"; id="${id%.jsonl}"
    [[ $id =~ $SESSION_RE ]] && F_STAT["$id"]="$b $m"
  done < <(stat "${STAT_FMT[@]}" "${files[@]}" 2>/dev/null || true)
  [ "$QUIET_MIN" -gt 0 ] || return 0
  while IFS= read -r -d '' path; do
    rel="${path#"$PROJECTS/$fo/"}"; id="${rel%%/*}"; F_RECENT["${id%.jsonl}"]=1
  done < <(find "$PROJECTS/$fo" -type f -mmin "-$QUIET_MIN" -print0 2>/dev/null)
}
# What the transcript and its sidecar look like right now: bytes and mtime of
# the jsonl, then the number of sidecar files and their newest mtime.
session_snapshot() {
  local fo="$1" id="$2" side="$PROJECTS/$1/$2" n=0 newest=0 t
  if [ -d "$side" ]; then
    while IFS= read -r -d '' t; do
      n=$((n + 1)); t="$(file_stat "$t" | cut -d' ' -f2)"; [ "${t:-0}" -gt "$newest" ] && newest="$t"
    done < <(find "$side" -type f -print0)
  fi
  printf '%s %s %s' "$(file_stat "$PROJECTS/$fo/$id.jsonl")" "$n" "$newest"
}
skip() { N_SKIPPED=$((N_SKIPPED + 1)); }
# archive_session <folder> <id> <sweep|stable>: counts the outcome. A sweep
# reads the stat and the "still being written" mark that folder_scan left.
archive_session() {
  local fo="$1" id="$2" mode="$3" key="$1/$2" src="$PROJECTS/$1" j snap bytes mtime nside waited
  j="$src/$id.jsonl"
  if [ -n "${FORGOTTEN[$id]:-}" ]; then skip; return 0; fi
  # D5: deleted on purpose in the desktop app. Not archived; an existing copy
  # is kept, marked, and shown by status. Never deleted automatically.
  if [ -r "$src/$id.desktop-released.json" ] && jq -e '.reason == "delete"' "$src/$id.desktop-released.json" >/dev/null 2>&1; then
    if [ "${I_STATE[$key]:-}" = active ]; then index_edit "$fo" "$id" state deleted-in-claude; I_STATE[$key]=deleted-in-claude; log "$id: deleted in Claude, archived copy kept"; fi
    skip; return 0
  fi
  [ -f "$j" ] || { skip; return 0; }
  # Quiescence: a transcript still being written is taken later.
  if [ "$mode" = stable ]; then
    if [ "$STABLE_WAIT" = 1 ]; then
      sleep 3; waited=3
      while :; do
        snap="$(session_snapshot "$fo" "$id")"; sleep 2; waited=$((waited + 2))
        [ "$snap" = "$(session_snapshot "$fo" "$id")" ] && break
        if [ "$waited" -ge 30 ]; then N_DEFERRED=$((N_DEFERRED + 1)); log "$id: still changing after 30 s, deferred"; return 0; fi
      done
    fi
    read -r bytes mtime <<<"$(file_stat "$j")"
  else
    if [ -n "${F_RECENT[$id]:-}" ]; then N_DEFERRED=$((N_DEFERRED + 1)); return 0; fi
    read -r bytes mtime <<<"${F_STAT[$id]:-$(file_stat "$j")}"
  fi
  # The jsonl alone answers "unchanged" (the common case of a sweep); the
  # sidecar is walked only when something did change.
  if [ -n "${I_STATE[$key]:-}" ]; then
    if [ "$bytes" = "${I_BYTES[$key]}" ] && [ "$mtime" = "${I_MTIME[$key]}" ]; then skip; return 0; fi
    read -r _ _ nside _ <<<"$(session_snapshot "$fo" "$id")"
    if [ "$bytes" = "${I_BYTES[$key]}" ]; then
      if [ "$(sha_of < "$j")" = "${I_SHA[$key]}" ]; then
        index_edit "$fo" "$id" mtime "$mtime"; I_MTIME[$key]="$mtime"; skip; return 0
      fi
      supersede "$fo" "$id"
    elif [ "$bytes" -gt "${I_BYTES[$key]}" ] && [ $((nside + 1)) -ge "${I_FILES[$key]}" ] \
         && [ "$(head -c "${I_BYTES[$key]}" "$j" | sha_of)" = "${I_SHA[$key]}" ]; then
      :  # Append-only growth: the new bundle replaces the current one.
    else
      supersede "$fo" "$id"
    fi
  fi
  build_bundle "$fo" "$id"
}
# The current bundle becomes an older generation, kept for good.
supersede() {
  local fo="$1" id="$2" gen
  gen="$id.$(utc_stamp).tgz.age"
  [ -f "$RH/archive/$fo/$id.tgz.age" ] && mv "$RH/archive/$fo/$id.tgz.age" "$RH/archive/$fo/$gen"
  index_edit "$fo" "$id" supersede "$gen"
  index_forget_row "$fo/$id"
  log "$id: rewritten in Claude, previous copy kept as $gen"
}
RELEVIO_VERSION=""
build_bundle() {
  local fo="$1" id="$2" src="$PROJECTS/$1" dst="$RH/archive/$1" stage tmp="" before after p h n cwd ver bb jsha="" bytes mtime nfiles
  local -a st
  # Drops the half-built bundle (this function's stage and tmp) and counts it.
  drop() {  # <failed|deferred> <reason>
    rm -f "${tmp:-}"; rm -rf "$stage"
    if [ "$1" = failed ]; then N_FAILED=$((N_FAILED + 1)); LAST_ERROR="$2"; else N_DEFERRED=$((N_DEFERRED + 1)); fi
    log "$id: $2"
  }
  [ -n "$RELEVIO_VERSION" ] || RELEVIO_VERSION="$(relevio_version)"
  before="$(session_snapshot "$fo" "$id")"
  mkdir -p "$dst"; chmod 700 "$dst"
  # A bundle with no index line (a crash between the rename and the index
  # update) is never overwritten: it becomes a generation.
  if [ -f "$dst/$id.tgz.age" ] && [ -z "${I_STATE[$fo/$id]:-}" ]; then
    mv "$dst/$id.tgz.age" "$dst/$id.orphan-$(utc_stamp).tgz.age"; log "$id: bundle without index line kept as an orphan generation"
  fi
  stage="$(mktemp -d "$RH/tmp.XXXXXX")"
  # Regular files only: a symlink in a sidecar is not archived.
  ( cd "$src" && { printf '%s\0' "$id.jsonl"; [ -d "$id" ] && find "$id" -type f -print0; true; } ) > "$stage/list"
  if grep -q "$TAB" <<<"$(tr '\0' '\n' < "$stage/list")"; then drop failed "a file name in session $id holds a tab"; return 0; fi
  nfiles="$(tr -cd '\0' < "$stage/list" | wc -c | tr -d ' ')"
  if [ "$nfiles" -ne "$(( $(tr '\0' '\n' < "$stage/list" | wc -l) ))" ]; then drop failed "a file name in session $id holds a newline"; return 0; fi
  cwd="$(transcript_cwd "$src/$id.jsonl")"
  ver="$(grep -o '"version":"[^"]*"' "$src/$id.jsonl" 2>/dev/null | tail -1 | cut -d'"' -f4 || true)"
  {
    echo "relevio-archive-manifest $ARCHIVE_FORMAT"
    echo "session $id"
    echo "folder $fo"
    echo "cwd ${cwd:-$RELEVIO_NONE}" | tr '\t' '?'
    echo "cc_version ${ver:-$RELEVIO_NONE}"
    echo "relevio_version $RELEVIO_VERSION"
    echo "archived_at $(utc_iso)"
    echo "container tar"; echo "compression gzip"; echo "encryption age-v1"
    while IFS= read -r -d '' p; do
      h="$(sha_of < "$src/$p")"; [ "$p" = "$id.jsonl" ] && jsha="$h"
      echo "file $h $(file_stat "$src/$p" | cut -d' ' -f1) $p"
    done < "$stage/list"
  } > "$stage/MANIFEST"
  tmp="$dst/.$id.tgz.age.tmp.$$"
  tar -cf - -C "$stage" MANIFEST -C "$src" --null -T "$stage/list" | gzip -6 -c | "$AGE" -e -R "$RH/keys/recipients.txt" -o "$tmp" 2>>"$RH/log" \
    && st=("${PIPESTATUS[@]}") || st=("${PIPESTATUS[@]}")
  if [ "${st[0]}${st[1]}${st[2]}" != 000 ] || [ "$(head -1 "$tmp" 2>/dev/null)" != "age-encryption.org/v1" ]; then
    drop failed "encrypting session $id failed (tar ${st[0]:-?}, gzip ${st[1]:-?}, age ${st[2]:-?})"; return 0
  fi
  after="$(session_snapshot "$fo" "$id")"
  if [ "$before" != "$after" ]; then drop deferred "changed while archiving, deferred"; return 0; fi
  chmod 600 "$tmp"; mv "$tmp" "$dst/$id.tgz.age"; tmp=""
  read -r bytes mtime _ <<<"$before"
  bb="$(file_stat "$dst/$id.tgz.age" | cut -d' ' -f1)"
  index_edit "$fo" "$id" put "$(printf 'active\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$id" "$(field "$fo")" "$(field "$cwd")" "$(field "$ver")" "$bytes" "$jsha" "$mtime" "$nfiles" "$id.tgz.age" "$bb" "$(utc_iso)")"
  rm -rf "$stage"
  N_ARCHIVED=$((N_ARCHIVED + 1))
}
relevio_version() { sed -n 's/^# relevio v//p' "$(dirname "$SELF")/../hooks/session-start.sh" 2>/dev/null | head -1 | grep . || echo "$RELEVIO_NONE"; }

all_folders() { find "$PROJECTS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's|.*/||' | sort; }
repo_folders() {  # every folder whose cwd is the repo or one of its worktrees, or under them
  local dir="$1" fo r roots
  roots="$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  [ -n "$roots" ] || roots="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || die "$(relevio_safe "$dir") is not inside a git repository."
  folders_load
  while IFS= read -r fo; do
    folder_cwd "$fo"; [ -n "$FCWD" ] || continue
    while IFS= read -r r; do
      case "$FCWD" in "$r"|"$r"/*) printf '%s\n' "$fo"; break ;; esac
    done <<<"$roots"
  done < <(all_folders)
}
# Every session of the folders read from stdin, through archive_session.
# PROGRESS_TOTAL, when set, prints a line every 25 sessions.
PROGRESS_N=0; PROGRESS_TOTAL=""
archive_folders() {
  local fo id
  while IFS= read -r fo; do
    folder_scan "$fo"
    for id in "${!F_STAT[@]}"; do
      archive_session "$fo" "$id" sweep
      PROGRESS_N=$((PROGRESS_N + 1))
      if [ -n "$PROGRESS_TOTAL" ] && [ $((PROGRESS_N % 25)) -eq 0 ]; then echo "  $PROGRESS_N of $PROGRESS_TOTAL ($(counts))"; fi
    done
  done
}

# Shared entry of every archiving run: nothing happens when archiving is off
# or not set up (the session-start notice says so instead).
begin_run() {  # $1 scope  $2 quiet|wait
  check_home
  [ ! -e "$RH/off" ] && is_set_up || return 1
  RUN_SCOPE="$1"
  load_config
  SHA="$(sha_tool)" || die "no sha256 tool (sha256sum or shasum) found."
  # Without the lock the status belongs to the run that holds it: only log.
  take_lock "$2" || { log "run $1: another run holds the lock, nothing done"; RUN_DONE=1; return 1; }
  status_write running ""
  index_init; index_load; forgotten_load
}
end_run() {
  if [ "$N_FAILED" -gt 0 ]; then status_write fail "$N_FAILED session(s) failed: ${LAST_ERROR:-see $RH/log}"
  else status_write ok ""; fi
  log "run $RUN_SCOPE: $(counts)"
  RUN_DONE=1
}

cmd_sync() {
  local scope="" sid="" transcript="" target="" stable=sweep fo l="" a
  local -a args=()
  for a in "$@"; do [ "$a" = --detach ] || args+=("$a"); done
  # --detach: run in the background, all three descriptors closed, so the
  # hook that asked never waits. Measured (Claude Code 2.1.316): a child
  # started this way finishes after the claude process has exited.
  if [ "${#args[@]}" -ne "$#" ]; then
    command -v setsid >/dev/null 2>&1 && l=setsid
    $l nohup bash "$SELF" sync "${args[@]}" </dev/null >/dev/null 2>&1 &
    exit 0
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sid="${2:-}"; scope=session; shift 2 ;;
      --transcript) transcript="${2:-}"; shift 2 ;;
      --wait-stable) stable=stable; shift ;;
      --repo) target="${2:-}"; scope=repo; shift 2 ;;
      --folder) target="${2:-}"; scope=folder; shift 2 ;;
      --all) scope=all; shift ;;
      # A session start: this project's repository, or, outside git, the
      # project folder its transcript sits in.
      --from-start) scope=start; shift ;;
      --project) target="${2:-}"; shift 2 ;;
      *) die "unknown sync argument '$(relevio_safe "$1")'" ;;
    esac
  done
  if [ "$scope" = start ]; then
    if git -C "${target:-.}" rev-parse --show-toplevel >/dev/null 2>&1; then
      scope=repo
    elif [ "$(dirname "$(dirname "$transcript")")" = "$PROJECTS" ]; then
      scope=folder; target="$(basename "$(dirname "$transcript")")"
    else
      exit 0
    fi
  fi
  [ -n "$scope" ] || die "sync needs --session, --repo, --folder, --all or --from-start."
  trap on_exit EXIT; trap 'exit 130' INT TERM
  case "$scope" in
    session)
      [[ $sid =~ $SESSION_RE ]] || die "'$(relevio_safe "$sid")' is not a session id."
      # The transcript must sit where relevio reads from; anything else is an
      # early sign that Claude Code changed its layout.
      fo="$(basename "$(dirname "$transcript")")"
      if [ "$(dirname "$(dirname "$transcript")")" != "$PROJECTS" ] || [ "$(basename "$transcript")" != "$sid.jsonl" ]; then
        check_home; [ -d "$RH" ] && is_set_up && { RUN_SCOPE=session; N_FAILED=1; status_write fail "transcript not where relevio expects it: $(relevio_safe "$transcript")"; RUN_DONE=1; }
        exit 0
      fi
      begin_run session wait || exit 0
      archive_session "$fo" "$sid" "$stable" ;;
    repo)
      begin_run repo quiet || exit 0
      archive_folders < <(repo_folders "$target") ;;
    folder)
      case "$target" in ""|*/*|.|..) die "'$(relevio_safe "$target")' is not a project folder name." ;; esac
      begin_run folder quiet || exit 0
      archive_folders <<<"$target" ;;
    all)
      begin_run all wait || exit 0
      archive_folders < <(all_folders) ;;
  esac
  end_run
}

# backfill: everything already on the machine, in the foreground, with progress.
cmd_backfill() {
  local total=0 bytes=0 need free fo id b
  check_home
  [ -e "$RH/off" ] && die "archiving is off: run 'on' first."
  is_set_up || die "the archive is not set up: run setup in your own terminal first."
  while IFS= read -r fo; do
    folder_scan "$fo"
    for id in "${!F_STAT[@]}"; do total=$((total + 1)); b="${F_STAT[$id]%% *}"; bytes=$((bytes + b)); done
  done < <(all_folders)
  # Bundles are about a quarter of the transcripts (gzip, measured 4x), plus
  # 30% margin, rounded up.
  need=$(( (bytes * 13 / 40 + 1023) / 1024 ))
  free="$(df -Pk "$RH" | awk 'NR == 2 { print $4 }')"
  free="${TEST_FREE_KB:-$free}"
  [ "$free" -ge "$need" ] || die "not enough free space for the archive: about $need KB needed, $free KB free on the disk holding $RH."
  echo "Archiving $total conversation(s), $(human_bytes "$bytes") of transcripts, into $RH."
  trap on_exit EXIT; trap 'exit 130' INT TERM
  begin_run all wait || die "another archiving run held the lock for ${LOCK_WAIT}s; try again in a minute."
  PROGRESS_TOTAL="$total"
  archive_folders < <(all_folders)
  end_run
  echo "Done: $(counts)."
  [ "$N_DEFERRED" -eq 0 ] || echo "Deferred sessions were still being written; the next session start archives them."
  [ "$N_FAILED" -eq 0 ] || { echo "Some sessions failed: details in $RH/log."; exit 1; }
}

# list [query]: what is archived, from the index alone. Nothing is decrypted.
cmd_list() {
  local q="${1:-}"
  check_home
  [ -s "$INDEX" ] || { echo "Nothing archived yet."; return 0; }
  printf '%-36s  %-16s  %10s  %-17s  %s\n' SESSION ARCHIVED SIZE STATE CWD
  tail -n +2 "$INDEX" | awk -F'\t' -v q="$q" '
    q == "" || index($2, q) == 1 || index($3, q) || index($4, q) {
      printf "%-36s  %-16s  %10s  %-17s  %s\n", $2, substr($12, 1, 10) " " substr($12, 12, 5), $11, $1, $4 }'
}

# --- Secrets: only in the user's terminal ----------------------------------------------
# The main identity comes from the passphrase (age asks on the terminal); the
# recovery identity is typed by the user. Either is kept in a variable, handed
# to age through a process substitution, and unset right after use.
read_main_identity() {
  if test_gate && [ -r "$RH/keys/main.key" ]; then cat "$RH/keys/main.key"; return 0; fi
  [ -r "$RH/keys/main.age" ] || die "$RH/keys/main.age is missing, so the passphrase cannot open anything. Use --recovery with your recovery key."
  "$AGE" -d "$RH/keys/main.age" || die "the passphrase did not open the main key. Try again, or use --recovery with your recovery key."
}
read_recovery_identity() {
  local k pub
  printf 'Recovery key (input hidden): ' >&2
  k="$(read_key_line)"
  pub="$(printf '%s\n' "$k" | "$AGE_KEYGEN" -y 2>/dev/null)" || die "that is not an age key: a recovery key starts with AGE-SECRET-KEY-1."
  grep -qxF "$pub" "$RH/keys/recipients.txt" || die "that key is not one of this archive's keys."
  printf '%s\n' "$k"
}
# Prints the identity for the run: --recovery picks the typed key.
identity_for() { if [ "$1" = recovery ]; then read_recovery_identity; else read_main_identity; fi; }
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- restore -------------------------------------------------------------------------
cmd_restore() {
  local id="" use=main gen="" replace=no want_fo="" lines n fo bundle st ab asha dest d stage idn other cur_b cur_sha cwd line ts
  while [ $# -gt 0 ]; do
    case "$1" in
      --recovery) use=recovery; shift ;;
      --generation) gen="${2:-}"; shift 2 ;;
      --replace) replace=yes; shift ;;
      --folder) want_fo="${2:-}"; shift 2 ;;
      -*) die "unknown restore option '$(relevio_safe "$1")'" ;;
      *) [ -z "$id" ] || die "give one session id"; id="$1"; shift ;;
    esac
  done
  check_home
  require_tty
  printf '%s' "$id" | grep -Eq "$SESSION_RE" || die "'$(relevio_safe "$id")' is not a session id (a UUID such as 14a94261-6409-412a-9ef9-dafb55e2cdbd)."
  is_set_up || die "the archive is not set up in $RH."
  load_config; SHA="$(sha_tool)"
  [ -s "$INDEX" ] || die "nothing is archived yet."
  if [ -n "$gen" ]; then
    lines="$(awk -F'\t' -v id="$id" -v g="$gen" 'NR > 1 && $2 == id && $10 == g' "$INDEX")"
    [ -n "$lines" ] || die "no generation '$(relevio_safe "$gen")' of session $id in the index (list shows them)."
  else
    lines="$(awk -F'\t' -v id="$id" -v f="$want_fo" 'NR > 1 && $2 == id && ($1 == "active" || $1 == "deleted-in-claude") && (f == "" || $3 == f)' "$INDEX")"
  fi
  if [ -z "$lines" ]; then
    echo "Session $id is not archived." >&2
    awk -F'\t' -v p="${id:0:8}" 'NR > 1 && index($2, p) == 1 { print "  near match: " $2 " (" $1 ", " $4 ")" }' "$INDEX" >&2
    exit 1
  fi
  n="$(printf '%s\n' "$lines" | grep -c .)"
  if [ "$n" -gt 1 ]; then
    echo "Session $id is archived from $n project folders; pick one with --folder:" >&2
    printf '%s\n' "$lines" | awk -F'\t' '{ print "  --folder " $3 "   (" $4 ")" }' >&2
    exit 1
  fi
  IFS="$TAB" read -r st _ fo _ _ ab asha _ _ bundle _ _ <<<"$lines"
  dest="$PROJECTS/$fo"
  # A copy of the same id in another folder makes claude --resume report it
  # as not found: never create that duplicate.
  other="$(find "$PROJECTS" -mindepth 2 -maxdepth 2 -name "$id.jsonl" -not -path "$dest/*" -print -quit 2>/dev/null)"
  [ -z "$other" ] || die "session $id already exists in another folder ($(relevio_safe "$other")); a second copy would make claude --resume fail. Nothing was restored."
  if [ -e "$dest/$id.jsonl" ]; then
    read -r cur_b _ <<<"$(file_stat "$dest/$id.jsonl")"
    cur_sha="$(head -c "$ab" "$dest/$id.jsonl" | sha_of)"
    if [ "$cur_b" -ge "$ab" ] && [ "$cur_sha" = "$asha" ]; then
      echo "Session $id is already in place and intact (the archived copy is a prefix of it); nothing to restore."
      print_resume "$(manifest_cwd_from_index "$id" "$fo")" "$id"; return 0
    fi
    [ "$replace" = yes ] || die "a different copy of session $id is in $dest. Nothing was restored. To put the archived copy back anyway, rerun with --replace: the current copy is moved aside, never deleted."
    if [ -n "$(find "$dest/$id.jsonl" -mmin -10 -print -quit 2>/dev/null)" ]; then
      die "the current copy of session $id was written less than 10 minutes ago: that conversation may be open right now. Close it, wait, and rerun."
    fi
  fi
  mkdir -p "$dest"; chmod 700 "$dest"
  stage="$(mktemp -d "$dest/.relevio-restore.XXXXXX")"
  # Global on purpose: the EXIT trap runs after this function's locals are gone.
  RESTORE_STAGE="$stage"
  trap 'rm -rf "${RESTORE_STAGE:-}"' EXIT
  idn="$(identity_for "$use")"
  "$AGE" -d -i <(printf '%s\n' "$idn") "$RH/archive/$fo/$bundle" > "$stage/bundle.tgz" 2>/dev/null \
    || { unset idn; die "that key could not open $bundle. Nothing was restored."; }
  unset idn
  gzip -dc < "$stage/bundle.tgz" > "$stage/bundle.tar" || die "$bundle is damaged (it does not decompress). Nothing was restored."
  # Only what an archive bundle may hold, checked BEFORE anything is extracted.
  tar -tf "$stage/bundle.tar" > "$stage/entries" || die "$bundle is damaged (not a tar stream). Nothing was restored."
  while IFS= read -r line; do
    case "$line" in
      MANIFEST|"$id.jsonl"|"$id/"|"$id"/*) ;;
      *) die "$bundle holds an unexpected entry ($(relevio_safe "$line")). Nothing was restored." ;;
    esac
    case "/$line/" in */../*) die "$bundle holds a path with '..'. Nothing was restored." ;; esac
  done < "$stage/entries"
  mkdir "$stage/x"
  tar -xf "$stage/bundle.tar" -C "$stage/x" --no-same-owner 2>/dev/null || die "$bundle could not be unpacked. Nothing was restored."
  [ -z "$(find "$stage/x" ! -type f ! -type d -print -quit)" ] || die "$bundle holds a link or a device file. Nothing was restored."
  [ "$(head -1 "$stage/x/MANIFEST" 2>/dev/null)" = "relevio-archive-manifest $ARCHIVE_FORMAT" ] \
    || die "$bundle was made by a newer relevio (or is damaged): its manifest is not format $ARCHIVE_FORMAT. Update relevio."
  local k h b p
  while read -r k h b p; do
    [ "$k" = file ] || continue
    [ -f "$stage/x/$p" ] && [ "$(sha_of < "$stage/x/$p")" = "$h" ] && [ "$(file_stat "$stage/x/$p" | cut -d' ' -f1)" = "$b" ] \
      || die "$bundle failed its integrity check ($(relevio_safe "$p")). Nothing was restored."
  done < "$stage/x/MANIFEST"
  [ "$(sha_of < "$stage/x/$id.jsonl")" = "$asha" ] || die "$bundle does not match its index entry. Nothing was restored."
  cwd="$(sed -n 's/^cwd //p' "$stage/x/MANIFEST" | head -1)"
  if [ -e "$dest/$id.jsonl" ]; then
    ts="$(utc_stamp)"
    mv "$dest/$id.jsonl" "$dest/$id.jsonl.relevio-replaced-$ts"
    [ -e "$dest/$id" ] && mv "$dest/$id" "$dest/$id.relevio-replaced-$ts"
    echo "The copy that was there is kept as $id.jsonl.relevio-replaced-$ts."
  fi
  [ ! -e "$dest/$id.jsonl" ] && [ ! -e "$dest/$id" ] || die "something appeared at $dest/$id while restoring. Nothing was restored."
  mv "$stage/x/$id.jsonl" "$dest/$id.jsonl"
  [ -d "$stage/x/$id" ] && mv "$stage/x/$id" "$dest/$id"
  chmod 600 "$dest/$id.jsonl"
  # Fresh mtime: Claude Code's age-based cleanup must not delete it again at
  # the next start.
  touch "$dest/$id.jsonl"
  echo "Restored session $id into $dest."
  [ "$st" = deleted-in-claude ] && echo "Note: you had deleted this session in Claude earlier."
  print_resume "$cwd" "$id"
}
manifest_cwd_from_index() { awk -F'\t' -v id="$1" -v f="$2" 'NR > 1 && $2 == id && $3 == f && $1 != "superseded" { print $4; exit }' "$INDEX"; }
print_resume() {  # $1 cwd  $2 id
  echo
  if [ -n "$1" ] && [ "$1" != "$RELEVIO_NONE" ] && [ -d "$1" ]; then
    echo "Reopen it with:"; echo; echo "  cd $(shell_quote "$1") && claude --resume $2"
  else
    echo "Its project folder ($(relevio_safe "${1:-unknown}")) no longer exists. Reopen it with:"; echo; echo "  claude --resume $2"
  fi
  echo
  echo "Reopening sends the whole conversation to the model again, so the first message costs a full context load."
}

# --- keys ----------------------------------------------------------------------------
cmd_keys() {
  local sub="${1:-}" use=main
  [ "${2:-}" = --recovery ] && use=recovery
  check_home; require_tty
  is_set_up || die "the archive is not set up in $RH."
  load_config
  case "$sub" in
    check) keys_check "$use" ;;
    passphrase) keys_passphrase ;;
    reset) keys_reset ;;
    *) die "keys needs check [--recovery], passphrase or reset." ;;
  esac
}
keys_check() {
  local idn
  idn="$(identity_for "$1")"
  if canary_opens "$idn"; then
    unset idn; [ "$1" = recovery ] && echo "recovery key works." || echo "passphrase works."
  else
    unset idn; echo "that key does NOT open the archive." >&2; exit 1
  fi
}
keys_passphrase() {
  local idn
  test_gate && [ -r "$RH/keys/main.key" ] && die "the test keys have no passphrase to change."
  echo "First the CURRENT passphrase:"
  idn="$(read_main_identity)"
  echo "Now the NEW passphrase (age asks twice):"
  printf '%s\n' "$idn" | "$AGE" -p -o "$RH/keys/main.age.tmp" || { unset idn; rm -f "$RH/keys/main.age.tmp"; die "the new passphrase was not set; the old one still works."; }
  unset idn
  mv "$RH/keys/main.age.tmp" "$RH/keys/main.age"
  echo "Passphrase changed. The recovery key is unchanged."
}
# Lost passphrase: the recovery key re-encrypts everything to a new main key.
# Nothing old is touched until every new bundle has been proven to open.
keys_reset() {
  local rec rec_pub main main_pub ts f rel new n=0 total
  trap 'rm -rf "$RH/archive.new" "$RH/keys/recipients.txt.new" "$RH/keys/main.new.age" "$RH/keys/main.new.key"; release_lock' EXIT
  take_lock wait || die "another archiving run holds the lock; try again in a minute."
  rec="$(read_recovery_identity)"
  rec_pub="$(printf '%s\n' "$rec" | "$AGE_KEYGEN" -y)"
  main="$("$AGE_KEYGEN" 2>/dev/null)"; main_pub="$(printf '%s\n' "$main" | "$AGE_KEYGEN" -y)"
  test_gate || echo "Choose the NEW passphrase (age asks twice):"
  protect_main_key "$main" "$RH/keys/main.new" || die "the new passphrase was not set; nothing changed."
  write_recipients "$main_pub" "$rec_pub" "$RH/keys/recipients.txt.new"
  total="$(find "$RH/archive" -name '*.age' -type f | grep -c . || true)"
  mkdir -p "$RH/archive.new"
  while IFS= read -r -d '' f; do
    rel="${f#"$RH/archive/"}"; new="$RH/archive.new/$rel"
    mkdir -p "$(dirname "$new")"
    n=$((n + 1))
    [ -n "$TEST_FAIL_AFTER" ] && [ "$n" -gt "$TEST_FAIL_AFTER" ] && die "test: forced failure after $TEST_FAIL_AFTER bundle(s); nothing changed."
    "$AGE" -d -i <(printf '%s\n' "$rec") "$f" | "$AGE" -e -R "$RH/keys/recipients.txt.new" -o "$new" \
      || die "re-encrypting $(relevio_safe "$rel") failed; nothing changed."
    "$AGE" -d -i <(printf '%s\n' "$main") "$new" > /dev/null 2>&1 || die "the re-encrypted $(relevio_safe "$rel") does not open with the new key; nothing changed."
    echo "  re-encrypted $n of $total"
  done < <(find "$RH/archive" -name '*.age' -type f -print0)
  unset rec main
  ts="$(utc_stamp)"
  mkdir -p "$RH/keys/old"
  [ -e "$RH/keys/main.age" ] && mv "$RH/keys/main.age" "$RH/keys/old/main.$ts.age"
  [ -e "$RH/keys/main.key" ] && mv "$RH/keys/main.key" "$RH/keys/old/main.$ts.key"
  mv "$RH/archive" "$RH/archive.old.$ts"
  mv "$RH/archive.new" "$RH/archive"
  mv "$RH/keys/recipients.txt.new" "$RH/keys/recipients.txt"
  if [ -e "$RH/keys/main.new.key" ]; then mv "$RH/keys/main.new.key" "$RH/keys/main.key"; else mv "$RH/keys/main.new.age" "$RH/keys/main.age"; fi
  write_canary
  rm -rf "$RH/archive.old.$ts"
  log "keys reset: $n bundle(s) re-encrypted to a new main key"
  echo "Done: $n bundle(s) now open with the new passphrase. The recovery key is the same."
}

# --- forget ------------------------------------------------------------------------
# Removes a session from the archive for good, and keeps it from coming back.
cmd_forget() {
  local id="${1:-}" files typed f
  check_home; require_tty
  printf '%s' "$id" | grep -Eq "$SESSION_RE" || die "'$(relevio_safe "$id")' is not a session id."
  is_set_up || die "the archive is not set up in $RH."
  files="$(awk -F'\t' -v id="$id" 'NR > 1 && $2 == id { print $3 "/" $10 }' "$INDEX" 2>/dev/null)"
  [ -n "$files" ] || die "session $id is not archived."
  echo "This removes from the archive, FOR GOOD:"
  while IFS= read -r f; do echo "  $f ($(human_bytes "$(file_stat "$RH/archive/$f" | cut -d' ' -f1)"))"; done <<<"$files"
  echo "and the session will never be archived again. This cannot be undone."
  printf 'Type the first 8 characters of the id to confirm: '
  if test_gate; then IFS= read -r typed || typed=""; else IFS= read -r typed < /dev/tty || typed=""; fi
  [ "$typed" = "${id:0:8}" ] || die "that does not match; nothing was removed."
  take_lock wait || die "another archiving run holds the lock; try again in a minute."
  trap release_lock EXIT
  while IFS= read -r f; do rm -f "$RH/archive/$f"; done <<<"$files"
  awk -F'\t' -v id="$id" 'NR == 1 || $2 != id' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  printf '%s\t%s\n' "$id" "$(utc_iso)" >> "$RH/forgotten.tsv"
  log "forgot $id"
  echo "Removed. Session $id will not be archived again."
}

# --- notice ---------------------------------------------------------------------------
# The one line the session-start hook puts in its notice slot, or nothing. The
# hooks read the archive only through this script, so the status format, the
# thresholds and the sanitizing live here alone. Never fails: a hook must not.
cmd_notice() {
  local err k v st="" at=0 pid=0 msg="" mark
  if ! err="$( (check_home) 2>&1 )"; then
    echo "ARCHIVE FAILING: $(printf '%s' "${err#ERROR: }" | LC_ALL=C tr -c 'A-Za-z0-9 ._/:(),-' '?' | cut -c1-200). Tell the user in one line."
    return 0
  fi
  [ ! -e "$RH/off" ] || return 0
  if ! is_set_up; then
    # At most once a day per machine: a reminder, not a nag. The marker
    # directory is refused when it is a symlink or someone else's, as the
    # context hook refuses it.
    mark="${XDG_CACHE_HOME:-$HOME/.cache}/relevio/markers"
    mkdir -p "$mark" 2>/dev/null && chmod 700 "$mark" 2>/dev/null
    [ ! -L "$mark" ] && [ -d "$mark" ] && [ -O "$mark" ] || return 0
    mark="$mark/archive-notice-$(date +%Y%m%d)"
    [ ! -e "$mark" ] || return 0
    : > "$mark" 2>/dev/null || return 0
    echo "ARCHIVE NOT SET UP: relevio is not archiving this machine's conversations yet. Tell the user in one line that they can set it up in their own terminal with: bash \"$SELF\" setup (or 'off' to stop this notice). Never run setup yourself: it asks for a passphrase."
    return 0
  fi
  if [ -r "$RH/keys/main.key" ]; then
    echo "ARCHIVE USES INSECURE TEST KEYS: its main key is stored unprotected. Tell the user in one line."
    return 0
  fi
  [ -r "$RH/status" ] || return 0
  while read -r k v; do
    case "$k" in state) st="$v" ;; at) at="$v" ;; pid) pid="$v" ;; message) msg="$v" ;; esac
  done < "$RH/status"
  case "$at" in ""|*[!0-9]*) at=0 ;; esac
  case "$pid" in ""|*[!0-9]*) pid=0 ;; esac
  case "$st" in
    fail)
      echo "ARCHIVE FAILING since $(fmt_time "$at"): $(printf '%s' "$msg" | LC_ALL=C tr -c 'A-Za-z0-9 ._/:(),-' '?' | cut -c1-150). Tell the user in one line; the details are in: bash \"$SELF\" status" ;;
    running)
      kill -0 "$pid" 2>/dev/null || echo "ARCHIVE INTERRUPTED: the last archiving run stopped before finishing; the next one resumes it. Tell the user in one line only if they ask about the archive." ;;
    ok)
      [ $(( $(date +%s) - at )) -le $((7 * 86400)) ] \
        || echo "ARCHIVE STALE: no archiving run has succeeded in over a week. Tell the user in one line; the details are in: bash \"$SELF\" status" ;;
  esac
  return 0
}

# session-start --project <dir> --transcript <path> [--no-notice]: the one
# call the session-start hook makes. It prints the notice (unless the hook's
# slot is already taken), then launches this start's sweep in the background.
# The notice reports the PREVIOUS run, so it is read before the sweep starts.
cmd_session_start() {
  local project="" transcript="" notice=yes
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project="${2:-}"; shift 2 ;;
      --transcript) transcript="${2:-}"; shift 2 ;;
      --no-notice) notice=no; shift ;;
      *) die "unknown session-start argument '$(relevio_safe "$1")'" ;;
    esac
  done
  [ "$notice" = no ] || cmd_notice
  cmd_sync --from-start --project "$project" --transcript "$transcript" --detach
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
  notice) cmd_notice ;;
  session-start) shift; cmd_session_start "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  backfill) cmd_backfill ;;
  list) cmd_list "${2:-}" ;;
  restore) shift; cmd_restore "$@" ;;
  keys) shift; cmd_keys "$@" ;;
  forget) cmd_forget "${2:-}" ;;
  off) cmd_off ;;
  on) cmd_on ;;
  -h|--help|help|"") relevio_usage "${BASH_SOURCE[0]}"; [ -n "${1:-}" ] || exit 2 ;;
  *) die "unknown command '$(relevio_safe "$1")'. Run with --help for the list." ;;
esac
