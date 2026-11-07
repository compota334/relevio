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
#   off       stop archiving new sessions (what is archived stays)
#   on        start again after off
#   sync      what the hooks run: --session <id> --transcript <path> [--wait-stable],
#             --repo <dir>, --folder <project folder name>, or --all
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
QUIET_MIN=2; LOCK_WAIT=120; STABLE_WAIT=1
if test_gate; then
  QUIET_MIN="${RELEVIO_TEST_QUIET_MIN:-$QUIET_MIN}"
  LOCK_WAIT="${RELEVIO_TEST_LOCK_WAIT:-$LOCK_WAIT}"
  STABLE_WAIT="${RELEVIO_TEST_STABLE_WAIT:-$STABLE_WAIT}"
fi

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$RH/log"; }
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
declare -A I_BYTES I_SHA I_MTIME I_FILES I_BUNDLE I_STATE
index_load() {
  local st id fo cwd ver by sha mt fi bu bb at
  I_BYTES=(); I_SHA=(); I_MTIME=(); I_FILES=(); I_BUNDLE=(); I_STATE=()
  [ -s "$INDEX" ] || return 0
  [ "$(head -1 "$INDEX")" = "$INDEX_HEADER" ] || die "$INDEX is not a format $ARCHIVE_FORMAT index (first line: '$(relevio_safe "$(head -1 "$INDEX" | cut -c1-60)")')."
  while IFS="$TAB" read -r st id fo cwd ver by sha mt fi bu bb at; do
    case "$st" in active|deleted-in-claude) ;; *) continue ;; esac
    I_STATE["$fo/$id"]="$st"; I_BYTES["$fo/$id"]="$by"; I_SHA["$fo/$id"]="$sha"
    I_MTIME["$fo/$id"]="$mt"; I_FILES["$fo/$id"]="$fi"; I_BUNDLE["$fo/$id"]="$bu"
  done < <(tail -n +2 "$INDEX")
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
# folder, and cached in folders.tsv.
folder_cwd() {
  local fo="$1" c f
  c="$(awk -F'\t' -v fo="$fo" '$1 == fo { print $2; exit }' "$RH/folders.tsv" 2>/dev/null || true)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  for f in "$PROJECTS/$fo"/*.jsonl; do
    [ -r "$f" ] || continue
    c="$(grep -m1 '"cwd":' "$f" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null || true)"
    [ -n "$c" ] && break
  done
  if [ -z "$c" ]; then log "folder $fo: no readable cwd, skipped"; return 0; fi
  printf '%s\t%s\t%s\n' "$fo" "$(printf '%s' "$c" | tr '\t\n' '??')" "$(date +%s)" >> "$RH/folders.tsv"
  printf '%s' "$c"
}

# --- one session ----------------------------------------------------------------------
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
# archive_session <folder> <id> <sweep|stable>: counts the outcome.
archive_session() {
  local fo="$1" id="$2" mode="$3" key="$1/$2" src="$PROJECTS/$1" j snap bytes mtime nfiles waited sha
  j="$src/$id.jsonl"
  if grep -qxF "$id" <(cut -f1 "$RH/forgotten.tsv" 2>/dev/null); then N_SKIPPED=$((N_SKIPPED + 1)); return 0; fi
  # D5: deleted on purpose in the desktop app. Not archived; an existing copy
  # is kept, marked, and shown by status. Never deleted automatically.
  if [ -r "$src/$id.desktop-released.json" ] && jq -e '.reason == "delete"' "$src/$id.desktop-released.json" >/dev/null 2>&1; then
    if [ "${I_STATE[$key]:-}" = active ]; then index_edit "$fo" "$id" state deleted-in-claude; I_STATE[$key]=deleted-in-claude; log "$id: deleted in Claude, archived copy kept"; fi
    N_SKIPPED=$((N_SKIPPED + 1)); return 0
  fi
  [ -f "$j" ] || { N_SKIPPED=$((N_SKIPPED + 1)); return 0; }
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
  elif [ "$QUIET_MIN" -gt 0 ] && [ -n "$(find "$j" "$src/$id" -type f -mmin "-$QUIET_MIN" -print -quit 2>/dev/null)" ]; then
    N_DEFERRED=$((N_DEFERRED + 1)); return 0
  fi
  # The jsonl alone answers "unchanged" (the common case of a sweep); the
  # sidecar is walked only when something did change.
  read -r bytes mtime <<<"$(file_stat "$j")"
  if [ -n "${I_BYTES[$key]:-}" ]; then
    if [ "$bytes" = "${I_BYTES[$key]}" ] && [ "$mtime" = "${I_MTIME[$key]}" ]; then N_SKIPPED=$((N_SKIPPED + 1)); return 0; fi
    read -r _ _ nfiles _ <<<"$(session_snapshot "$fo" "$id")"
    if [ "$bytes" = "${I_BYTES[$key]}" ]; then
      sha="$(sha_of < "$j")"
      if [ "$sha" = "${I_SHA[$key]}" ]; then
        index_edit "$fo" "$id" mtime "$mtime"; I_MTIME[$key]="$mtime"; N_SKIPPED=$((N_SKIPPED + 1)); return 0
      fi
      supersede "$fo" "$id"
    elif [ "$bytes" -gt "${I_BYTES[$key]}" ] && [ "$nfiles" -ge "$(( ${I_FILES[$key]} - 1 ))" ] \
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
  gen="$id.$(date -u +%Y%m%dT%H%M%SZ).tgz.age"
  [ -f "$RH/archive/$fo/$id.tgz.age" ] && mv "$RH/archive/$fo/$id.tgz.age" "$RH/archive/$fo/$gen"
  index_edit "$fo" "$id" supersede "$gen"
  unset "I_BYTES[$fo/$id]"
  log "$id: rewritten in Claude, previous copy kept as $gen"
}
build_bundle() {
  local fo="$1" id="$2" src="$PROJECTS/$1" dst="$RH/archive/$1" stage tmp before after p n cwd ver line bb
  local -a st
  before="$(session_snapshot "$fo" "$id")"
  mkdir -p "$dst"; chmod 700 "$dst"
  # A bundle with no index line (a crash between the rename and the index
  # update) is never overwritten: it becomes a generation.
  if [ -f "$dst/$id.tgz.age" ] && [ -z "${I_BYTES[$fo/$id]:-}" ] && [ -z "${I_STATE[$fo/$id]:-}" ]; then
    mv "$dst/$id.tgz.age" "$dst/$id.orphan-$(date -u +%Y%m%dT%H%M%SZ).tgz.age"; log "$id: bundle without index line kept as an orphan generation"
  fi
  stage="$(mktemp -d "$RH/tmp.XXXXXX")"
  # Regular files only: a symlink in a sidecar is not archived.
  ( cd "$src" && { printf '%s\0' "$id.jsonl"; [ -d "$id" ] && find "$id" -type f -print0; true; } ) > "$stage/list"
  if grep -q "$TAB" <<<"$(tr '\0' '\n' < "$stage/list")"; then
    rm -rf "$stage"; N_FAILED=$((N_FAILED + 1)); LAST_ERROR="a file name in session $id holds a tab"; log "$id: a file name holds a tab, not archived"; return 0
  fi
  n="$(tr -cd '\0' < "$stage/list" | wc -c | tr -d ' ')"
  if [ "$n" -ne "$(( $(tr '\0' '\n' < "$stage/list" | wc -l) ))" ]; then
    rm -rf "$stage"; N_FAILED=$((N_FAILED + 1)); LAST_ERROR="a file name in session $id holds a newline"; log "$id: a file name holds a newline, not archived"; return 0
  fi
  cwd="$(grep -m1 '"cwd":' "$src/$id.jsonl" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null || true)"
  ver="$(grep -o '"version":"[^"]*"' "$src/$id.jsonl" 2>/dev/null | tail -1 | cut -d'"' -f4 || true)"
  {
    echo "relevio-archive-manifest $ARCHIVE_FORMAT"
    echo "session $id"
    echo "folder $fo"
    echo "cwd ${cwd:-$RELEVIO_NONE}" | tr '\t' '?'
    echo "cc_version ${ver:-$RELEVIO_NONE}"
    echo "relevio_version $(relevio_version)"
    echo "archived_at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "container tar"; echo "compression gzip"; echo "encryption age-v1"
    while IFS= read -r -d '' p; do
      echo "file $(sha_of < "$src/$p") $(file_stat "$src/$p" | cut -d' ' -f1) $p"
    done < "$stage/list"
  } > "$stage/MANIFEST"
  tmp="$dst/.$id.tgz.age.tmp.$$"
  tar -cf - -C "$stage" MANIFEST -C "$src" --null -T "$stage/list" | gzip -6 -c | "$AGE" -e -R "$RH/keys/recipients.txt" -o "$tmp" 2>>"$RH/log" \
    && st=("${PIPESTATUS[@]}") || st=("${PIPESTATUS[@]}")
  if [ "${st[0]}${st[1]}${st[2]}" != 000 ] || [ "$(head -1 "$tmp" 2>/dev/null)" != "age-encryption.org/v1" ]; then
    rm -f "$tmp"; rm -rf "$stage"; N_FAILED=$((N_FAILED + 1))
    LAST_ERROR="encrypting session $id failed (tar ${st[0]:-?}, gzip ${st[1]:-?}, age ${st[2]:-?})"; log "$id: $LAST_ERROR"; return 0
  fi
  after="$(session_snapshot "$fo" "$id")"
  if [ "$before" != "$after" ]; then
    rm -f "$tmp"; rm -rf "$stage"; N_DEFERRED=$((N_DEFERRED + 1)); log "$id: changed while archiving, deferred"; return 0
  fi
  chmod 600 "$tmp"; mv "$tmp" "$dst/$id.tgz.age"
  read -r p n _ <<<"$before"
  bb="$(file_stat "$dst/$id.tgz.age" | cut -d' ' -f1)"
  line="active$TAB$id$TAB$(field "$fo")$TAB$(field "$cwd")$TAB$(field "$ver")$TAB$p$TAB$(sha_of < "$src/$id.jsonl")$TAB$n$TAB$(grep -c . <(tr '\0' '\n' < "$stage/list"))$TAB$id.tgz.age$TAB$bb$TAB$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  index_edit "$fo" "$id" put "$line"
  rm -rf "$stage"
  N_ARCHIVED=$((N_ARCHIVED + 1))
}
relevio_version() { sed -n 's/^# relevio v//p' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" 2>/dev/null && pwd)/session-start.sh" 2>/dev/null | head -1 | grep . || echo "$RELEVIO_NONE"; }

# Every session file directly in a project folder; nothing else (memory/,
# sessions-index.json, *.desktop-released.json, set-aside copies) is a session.
sessions_in() {
  local f id
  for f in "$PROJECTS/$1"/*.jsonl; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .jsonl)"
    printf '%s' "$id" | grep -Eq "$SESSION_RE" && printf '%s\n' "$id"
  done
  return 0
}
all_folders() { find "$PROJECTS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's|.*/||' | LC_ALL=C sort; }
repo_folders() {  # every folder whose cwd is the repo or one of its worktrees, or under them
  local dir="$1" fo c roots
  roots="$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  [ -n "$roots" ] || roots="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || die "$(relevio_safe "$dir") is not inside a git repository."
  while IFS= read -r fo; do
    c="$(folder_cwd "$fo")"; [ -n "$c" ] || continue
    while IFS= read -r r; do
      case "$c" in "$r"|"$r"/*) printf '%s\n' "$fo"; break ;; esac
    done <<<"$roots"
  done < <(all_folders)
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
  index_init; index_load
}
end_run() {
  if [ "$N_FAILED" -gt 0 ]; then status_write fail "$N_FAILED session(s) failed: ${LAST_ERROR:-see $RH/log}"
  else status_write ok ""; fi
  log "run $RUN_SCOPE: $(counts)"
  RUN_DONE=1
}

cmd_sync() {
  local scope="" sid="" transcript="" target="" stable=sweep fo id
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sid="${2:-}"; scope=session; shift 2 ;;
      --transcript) transcript="${2:-}"; shift 2 ;;
      --wait-stable) stable=stable; shift ;;
      --repo) target="${2:-}"; scope=repo; shift 2 ;;
      --folder) target="${2:-}"; scope=folder; shift 2 ;;
      --all) scope=all; shift ;;
      *) die "unknown sync argument '$(relevio_safe "$1")'" ;;
    esac
  done
  [ -n "$scope" ] || die "sync needs --session, --repo, --folder or --all."
  trap on_exit EXIT; trap 'exit 130' INT TERM
  case "$scope" in
    session)
      printf '%s' "$sid" | grep -Eq "$SESSION_RE" || die "'$(relevio_safe "$sid")' is not a session id."
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
      while IFS= read -r fo; do
        while IFS= read -r id; do archive_session "$fo" "$id" sweep; done < <(sessions_in "$fo")
      done < <(repo_folders "$target") ;;
    folder)
      case "$target" in ""|*/*|.|..) die "'$(relevio_safe "$target")' is not a project folder name." ;; esac
      begin_run folder quiet || exit 0
      while IFS= read -r id; do archive_session "$target" "$id" sweep; done < <(sessions_in "$target") ;;
    all)
      begin_run all wait || exit 0
      while IFS= read -r fo; do
        while IFS= read -r id; do archive_session "$fo" "$id" sweep; done < <(sessions_in "$fo")
      done < <(all_folders) ;;
  esac
  end_run
}

# backfill: everything already on the machine, in the foreground, with progress.
cmd_backfill() {
  local total=0 bytes=0 need free fo id done_n=0 f s
  check_home
  [ -e "$RH/off" ] && die "archiving is off: run 'on' first."
  is_set_up || die "the archive is not set up: run setup in your own terminal first."
  while IFS= read -r fo; do
    while IFS= read -r id; do
      total=$((total + 1)); s="$(file_stat "$PROJECTS/$fo/$id.jsonl" | cut -d' ' -f1)"; bytes=$((bytes + ${s:-0}))
    done < <(sessions_in "$fo")
  done < <(all_folders)
  # Bundles are about a quarter of the transcripts (gzip, measured 4x), plus
  # 30% margin, rounded up.
  need=$(( (bytes * 13 / 40 + 1023) / 1024 ))
  free="$(df -Pk "$RH" | awk 'NR == 2 { print $4 }')"
  test_gate && free="${RELEVIO_TEST_FREE_KB:-$free}"
  [ "$free" -ge "$need" ] || die "not enough free space for the archive: about $need KB needed, $free KB free on the disk holding $RH."
  echo "Archiving $total conversation(s), $(human_bytes "$bytes") of transcripts, into $RH."
  trap on_exit EXIT; trap 'exit 130' INT TERM
  begin_run all wait || die "another archiving run held the lock for ${LOCK_WAIT}s; try again in a minute."
  while IFS= read -r fo; do
    while IFS= read -r id; do
      archive_session "$fo" "$id" sweep; done_n=$((done_n + 1))
      [ $((done_n % 25)) -eq 0 ] && echo "  $done_n of $total ($(counts))"
    done < <(sessions_in "$fo")
  done < <(all_folders)
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
  sync) shift; cmd_sync "$@" ;;
  backfill) cmd_backfill ;;
  list) cmd_list "${2:-}" ;;
  off) cmd_off ;;
  on) cmd_on ;;
  -h|--help|help|"") relevio_usage "${BASH_SOURCE[0]}"; [ -n "${1:-}" ] || exit 2 ;;
  *) die "unknown command '$(relevio_safe "$1")'. Run with --help for the list." ;;
esac
