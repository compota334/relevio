# relevio archive: timestamps (OpenTimestamps). Sourced by relevio-archive.sh,
# never run on its own.
#
# A timestamp proves that one archived conversation, byte for byte, existed no
# later than a Bitcoin block, without trusting relevio, the user or this PC's
# clock. It does NOT prove who wrote it or that what it says is true.
#
# What is stamped, per archived generation, is a small "leaf" text file that
# holds sha256(salt + newline + transcript). The salt is random per
# generation, so the stamp (which public calendar servers see) reveals nothing,
# and nobody can confirm a guessed transcript against it. Only the hash of
# the leaf leaves the machine; the salt travels inside the encrypted catalog.
#
# The OpenTimestamps client builds one Merkle tree per call (measured: 2000
# leaves, one submission per calendar, 3.7 s), so leaves are stamped in
# batches: when the oldest waiting leaf is a day old, when 10 000 wait, or on
# `stamp now`. A few hours later Bitcoin confirms the batch and `upgrade`
# completes each proof.

STAMPS_TSV="$RH/stamps.tsv"
STAMPS_HEADER="#relevio-stamps	1"
STAMP_DIR="$RH/stamps"
OTS_CLIENT_VERSION="0.8.0"
# (their test overrides are read with every other test knob, in relevio-archive.sh)
STAMP_MAX_WAIT=86400; STAMP_MAX_BATCH=10000; STAMP_RETRY=3600; STAMP_UPGRADE_AFTER=3600
EXPLORERS=(https://blockstream.info/api https://mempool.space/api)
OTS_BIN=""; OTS_HELPER=(); TEST_OTS_BIN=""; TEST_OTS_HELPER=""

stamping_on() { [ "$(config_get stamping)" = on ]; }
# Sets OTS_BIN and OTS_HELPER from the venv recorded at stamp setup (or the
# test fakes under the gate).
stamps_load() {
  local venv; venv="$(config_get ots_venv)"
  if [ -n "$TEST_OTS_BIN" ]; then
    OTS_BIN="$TEST_OTS_BIN"; OTS_HELPER=(bash "$TEST_OTS_HELPER"); return 0
  fi
  [ -n "$venv" ] && [ -x "$venv/bin/ots" ] && [ -x "$venv/bin/python" ] \
    || die "the timestamp client is missing in '$(relevio_safe "$venv")': run stamp setup again."
  OTS_BIN="$venv/bin/ots"
  OTS_HELPER=("$venv/bin/python" -I "$(dirname "$SELF")/relevio-ots-helper.py")
}

# --- records ------------------------------------------------------------------------
# stamps.tsv: state id folder bundle salt leaf queued_at stamped_at height
# jsonl_sha256. A row belongs to one archived CONTENT (folder, session and the
# sha256 of its transcript), not to a bundle file name: a session rewritten in
# Claude gets a new generation, its old bundle is renamed, and the name
# <id>.tgz.age then holds other content. The bundle column only says where
# that content is now (stamp backfill opens it).
# state: pending (waiting for a batch), stamped (sent, waiting for Bitcoin),
# complete (in a Bitcoin block), needs-key (the transcript is no longer on
# this machine: stamp backfill opens the bundle to compute the leaf).
declare -A S_ROW
stamp_row() { local IFS="$TAB"; printf '%s' "$*"; }  # the 10 fields, in order
stamps_load_rows() {
  local st id fo b salt leaf q s h js
  S_ROW=()
  [ -s "$STAMPS_TSV" ] || return 0
  [ "$(head -1 "$STAMPS_TSV")" = "$STAMPS_HEADER" ] || die "$STAMPS_TSV is not a relevio stamp record."
  tsv_valid stamps "$STAMPS_TSV" || die "$STAMPS_TSV line $TSV_BAD is malformed."
  while IFS="$TAB" read -r st id fo b salt leaf q s h js; do
    [ -n "$js" ] && S_ROW["$fo/$id/$js"]="$(stamp_row "$st" "$id" "$fo" "$b" "$salt" "$leaf" "$q" "$s" "$h" "$js")"
  done < <(tail -n +2 "$STAMPS_TSV")
}
# Rows are saved only when something changed (a flag set by every writer).
S_DIRTY=0
stamps_save_dirty() { [ "$S_DIRTY" = 0 ] || stamps_save_rows; S_DIRTY=0; }
stamps_save_rows() {
  local k
  { printf '%s\n' "$STAMPS_HEADER"
    for k in "${!S_ROW[@]}"; do printf '%s\n' "${S_ROW[$k]}"; done | sort -t"$TAB" -k3,4; } > "$STAMPS_TSV.tmp"
  mv "$STAMPS_TSV.tmp" "$STAMPS_TSV"
}
# The leaf of a transcript (stdin) with a salt: the line a verifier recomputes
# with: (printf '%s\n' "<salt>"; cat conversation.jsonl) | sha256sum
salted_of() { { printf '%s\n' "$1"; cat; } | sha_of; }
leaf_text() { printf 'relevio timestamp leaf 1\nsalted-sha256 %s\n' "$1"; }
# Writes the leaf file and prints its name (the sha256 of its text).
leaf_write() {  # <salted hash>
  local name
  mkdir -p "$STAMP_DIR"; chmod 700 "$STAMP_DIR"
  name="$(leaf_text "$1" | sha_of)"
  leaf_text "$1" > "$STAMP_DIR/$name.leaf"
  printf '%s' "$name"
}
new_salt() { rand_hex 32; }

# --- queue: one leaf per archived generation ------------------------------------------
# The transcript is read from ~/.claude/projects when its first <archived
# bytes> still hash to what was archived (so the leaf is of exactly the
# archived content); otherwise the row waits for stamp backfill.
stamps_queue() {
  local st id fo cwd ver by sha mt fi b bb at j salt salted leaf added=0 k rst rb rsalt rleaf rq rs rh
  stamps_load_rows
  while IFS="$TAB" read -r st id fo cwd ver by sha mt fi b bb at; do
    k="$fo/$id/$sha"
    if [ -n "${S_ROW[$k]:-}" ]; then
      # Same content, renamed bundle (an older generation now): follow it.
      IFS="$TAB" read -r rst _ _ rb rsalt rleaf rq rs rh _ <<<"${S_ROW[$k]}"
      [ "$rb" = "$b" ] || { S_ROW["$k"]="$(stamp_row "$rst" "$id" "$fo" "$b" "$rsalt" "$rleaf" "$rq" "$rs" "$rh" "$sha")"; S_DIRTY=1; }
      continue
    fi
    j="$PROJECTS/$fo/$id.jsonl"
    if [ "$st" != superseded ] && [ -f "$j" ] && [ "$(head -c "$by" "$j" | sha_of)" = "$sha" ]; then
      salt="$(new_salt)"; salted="$(head -c "$by" "$j" | salted_of "$salt")"
      leaf="$(leaf_write "$salted")"
      S_ROW["$k"]="$(stamp_row pending "$id" "$fo" "$b" "$salt" "$leaf" "$(date +%s)" "$RELEVIO_NONE" "$RELEVIO_NONE" "$sha")"
    else
      S_ROW["$k"]="$(stamp_row needs-key "$id" "$fo" "$b" "$RELEVIO_NONE" "$RELEVIO_NONE" "$(date +%s)" "$RELEVIO_NONE" "$RELEVIO_NONE" "$sha")"
    fi
    added=$((added + 1)); S_DIRTY=1
  done < <(tail -n +2 "$INDEX" 2>/dev/null)
  stamps_save_dirty
}

# --- batch and upgrade ---------------------------------------------------------------
stamps_status_write() { kv_status_write "$RH/stamps.status" "$@"; }
stamps_status_field() { kv_status_field "$RH/stamps.status" "$1"; }
# earliest_bitcoin <attest output file> <name>: "<height> <merkle>" of the
# earliest Bitcoin block that proof <name> is anchored in, or nothing.
earliest_bitcoin() { awk -v n="$2" '$1 == n && $2 == "bitcoin" { print $3, $4 }' "$1" | sort -k1,1n | head -1; }
# throttled <config key> <seconds>: true (and the key set to now) when the last
# try was at least that long ago; force skips the wait.
throttled() {
  local last now; now="$(date +%s)"; last="$(config_get "$1")"
  [ "${3:-auto}" = force ] || [ -z "$last" ] || [ $((now - last)) -ge "$2" ] || return 1
  config_set "$1" "$now"
}
# stamps_batch <force|auto>: sends every pending leaf in one client call.
stamps_batch() {
  local k st q now oldest="" n=0 err id fo b salt leaf h js
  local -a files=()
  now="$(date +%s)"
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st _ _ _ _ leaf q _ <<<"${S_ROW[$k]}"
    [ "$st" = pending ] || continue
    files+=("$STAMP_DIR/$leaf.leaf"); n=$((n + 1))
    { [ -z "$oldest" ] || [ "$q" -lt "$oldest" ]; } && oldest="$q"
  done
  [ "$n" -gt 0 ] || return 0
  if [ "$1" = auto ]; then
    [ $((now - oldest)) -ge "$STAMP_MAX_WAIT" ] || [ "$n" -ge "$STAMP_MAX_BATCH" ] || return 0
  fi
  throttled stamp_last_try "$STAMP_RETRY" "$1" || return 0
  # At least 2 calendars must answer (measured: with one down the proof is
  # still made from the others; with none, the client fails and writes nothing).
  if ! err="$("$OTS_BIN" -q stamp -m 2 "${files[@]}" 2>&1)"; then
    R_ERR="no timestamp calendar answered ($(printf '%s' "$err" | tail -1 | safe_msg | cut -c1-120)); the $n leaf(s) stay queued"
    return 1
  fi
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st id fo b salt leaf q _ h js <<<"${S_ROW[$k]}"
    [ "$st" = pending ] && [ -s "$STAMP_DIR/$leaf.leaf.ots" ] || continue
    S_ROW["$k"]="$(stamp_row stamped "$id" "$fo" "$b" "$salt" "$leaf" "$q" "$now" "$h" "$js")"; S_DIRTY=1
  done
  log "stamps: $n leaf(s) sent to the calendars"
}
# stamps_upgrade <force|auto>: asks the calendars, at most once an hour, for
# the Bitcoin part of every proof sent at least an hour ago, then reads all of
# them in ONE helper call. A proof still pending stays stamped.
stamps_upgrade() {
  local k st id fo b salt leaf q s h js now line n=0 done_n=0 out="$RH/.attest"
  local -a files=()
  now="$(date +%s)"
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st _ _ _ _ leaf _ s _ <<<"${S_ROW[$k]}"
    [ "$st" = stamped ] || continue
    [ "$1" = force ] || [ $((now - s)) -ge "$STAMP_UPGRADE_AFTER" ] || continue
    files+=("$STAMP_DIR/$leaf.leaf.ots"); n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 0
  throttled stamp_last_upgrade "$STAMP_RETRY" "$1" || return 0
  # Exit status is not success while any proof is still waiting: read each.
  "$OTS_BIN" -q upgrade "${files[@]}" >/dev/null 2>&1 || true
  "${OTS_HELPER[@]}" attest "${files[@]}" > "$out" 2>/dev/null || true
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st id fo b salt leaf q s h js <<<"${S_ROW[$k]}"
    [ "$st" = stamped ] || continue
    line="$(earliest_bitcoin "$out" "$leaf.leaf.ots")"
    [ -n "$line" ] || continue
    read -r h _ <<<"$line"
    S_ROW["$k"]="$(stamp_row complete "$id" "$fo" "$b" "$salt" "$leaf" "$q" "$s" "$h" "$js")"; S_DIRTY=1
    done_n=$((done_n + 1))
  done
  rm -f "${out:?}"
  [ "$done_n" -eq 0 ] || log "stamps: $done_n proof(s) confirmed in Bitcoin"
}
# After every archiving run (lock held). Never fails the run: the stamp
# status says what went wrong.
stamp_after_run() {
  stamping_on || return 0
  run_isolated stamps_status_write stamp stamps_auto
}
stamps_auto() {
  R_ERR=""
  stamps_load; stamps_queue
  if stamps_batch auto; then
    stamps_upgrade auto; stamps_save_dirty; stamps_status_write ok ""
  else
    stamps_save_dirty; stamps_status_write fail "$R_ERR"; log "stamps: $R_ERR"
  fi
}

# --- commands ------------------------------------------------------------------------------
cmd_stamp() {
  local sub="${1:-}"; shift || true
  check_writable; is_set_up || die "the archive is not set up in $RH: run setup first."
  tools_load
  case "$sub" in
    setup) stamp_setup ;;
    status) stamp_show ;;
    now) stamp_now ;;
    backfill) stamp_backfill "$@" ;;
    off) config_unset stamping; echo "Timestamping is off. Proofs already made stay valid and stay in $STAMP_DIR." ;;
    *) die "stamp needs: setup | status | now | backfill | off" ;;
  esac
}
# The client lives in its own virtual environment inside the archive home,
# pinned to a version published long ago (this machine's package cooldown).
stamp_setup() {
  local venv="$RH/ots-venv" py
  if [ -z "$TEST_OTS_BIN" ]; then
    py="$(command -v python3)" || die "python3 is missing: on Ubuntu, sudo apt install python3 python3-venv."
    echo "Installing the OpenTimestamps client $OTS_CLIENT_VERSION into $venv (from PyPI, once)..."
    if command -v uv >/dev/null 2>&1; then
      uv venv -q "$venv" && uv pip install -q --python "$venv/bin/python" "opentimestamps-client==$OTS_CLIENT_VERSION" \
        || die "installing the client failed (network, or PyPI is down). Nothing changed; run stamp setup again later."
    else
      "$py" -m venv "$venv" || die "python3 cannot make a virtual environment: on Ubuntu, sudo apt install python3-venv."
      "$venv/bin/pip" install -q "opentimestamps-client==$OTS_CLIENT_VERSION" \
        || die "installing the client failed (network, or PyPI is down). Nothing changed; run stamp setup again later."
    fi
    "$venv/bin/ots" --version >/dev/null 2>&1 || die "the client was installed but does not run; nothing changed."
  fi
  config_set ots_venv "$venv"; config_set stamping on
  # The conversations archived before today join the queue now, so the user
  # hears how many will be stamped instead of a status that says 0.
  lock_or_die
  stamps_load; stamps_queue
  echo "Timestamping is on. Bitcoin confirms each batch a few hours after it is sent."
  stamp_show
  echo "Queued ones go out within a day by themselves, or now with: $SELF_CMD stamp now"
}
stamp_now() {
  stamping_on || die "timestamping is off: run stamp setup first."
  lock_or_die
  stamps_load; stamps_queue
  if ! stamps_batch force; then stamps_save_dirty; stamps_status_write fail "$R_ERR"; die "$R_ERR. Nothing is lost: they are sent next time."; fi
  stamps_upgrade force; stamps_save_dirty; stamps_status_write ok ""
  stamp_show
}
stamp_show() {
  local st k
  if ! stamping_on; then echo "stamps: off. Turn on with: stamp setup"; return 0; fi
  stamps_load_rows
  declare -A C=([pending]=0 [stamped]=0 [complete]=0 [needs-key]=0)
  for k in "${!S_ROW[@]}"; do st="${S_ROW[$k]%%$TAB*}"; C[$st]=$(( ${C[$st]:-0} + 1 )); done
  echo "stamps: ${C[complete]} proven in Bitcoin, ${C[stamped]} waiting for Bitcoin, ${C[pending]} queued for the next batch"
  [ "${C[needs-key]}" -eq 0 ] || echo "  ${C[needs-key]} need a key: their transcript is gone from this machine. Run in your terminal: $SELF_CMD stamp backfill"
  [ "$(stamps_status_field state)" = fail ] && echo "  last try FAILED: $(relevio_safe "$(stamps_status_field message)")"
  return 0
}
# Rows whose transcript is gone: open each bundle (user's terminal, a key)
# and compute the leaf from what was archived.
stamp_backfill() {
  local use=main idn k st id fo b n=0 salt salted leaf tmp js
  [ "${1:-}" = --recovery ] && use=recovery
  require_tty; stamping_on || die "timestamping is off: run stamp setup first."
  STAMP_TMP=""; lock_or_die STAMP_TMP
  stamps_queue
  for k in "${!S_ROW[@]}"; do [ "${S_ROW[$k]%%$TAB*}" = needs-key ] && n=$((n + 1)); done
  [ "$n" -gt 0 ] || { echo "Nothing needs a key: every archived conversation has its leaf."; return 0; }
  echo "$n archived conversation(s) are no longer on this machine; opening them to compute their leaf (nothing is written in clear outside a private temporary folder)."
  idn="$(identity_for "$use" "Opening archived conversations to timestamp them.")"
  STAMP_TMP="$(mktemp -d "$RH/.stamp.XXXXXX")"; tmp="$STAMP_TMP"
  n=0
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st id fo b _ _ _ _ _ js <<<"${S_ROW[$k]}"
    [ "$st" = needs-key ] || continue
    index_names_ok "$id" "$fo" "$b" || continue
    "$AGE" -d -i <(printf '%s\n' "$idn") "$RH/archive/$fo/$b" 2>/dev/null | gzip -dc | tar -xf - -C "$tmp" "$id.jsonl" 2>/dev/null \
      || { log "stamp backfill: could not open $fo/$b"; continue; }
    salt="$(new_salt)"; salted="$(salted_of "$salt" < "$tmp/$id.jsonl")"; rm -f "$tmp/$id.jsonl"
    leaf="$(leaf_write "$salted")"
    S_ROW["$k"]="$(stamp_row pending "$id" "$fo" "$b" "$salt" "$leaf" "$(date +%s)" "$RELEVIO_NONE" "$RELEVIO_NONE" "$js")"; S_DIRTY=1
    n=$((n + 1))
  done
  unset idn
  stamps_save_rows
  echo "Done: $n leaf(s) computed; they go out in the next batch (or now: stamp now)."
}

# --- proof: the folder a colleague, an auditor or a court can check ---------------------------
cmd_proof() {
  local id="${1:-}" out="" use=main want_fo="" fo b st salt leaf h row j by sha lines n
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      --recovery) use=recovery; shift ;;
      --folder) want_fo="${2:-}"; shift 2 ;;
      *) die "unknown proof option '$(relevio_safe "$1")'" ;;
    esac
  done
  check_home; is_set_up || die "the archive is not set up in $RH."
  tools_load
  [[ $id =~ $SESSION_RE ]] || die "'$(relevio_safe "$id")' is not a session id."
  # The current generation of the session, from the index (as restore picks
  # it), then its stamp by content.
  lines="$(awk -F'\t' -v id="$id" -v f="$want_fo" 'NR > 1 && $2 == id && ($1 == "active" || $1 == "deleted-in-claude") && (f == "" || $3 == f) { print $3 "\t" $10 "\t" $6 "\t" $7 }' "$INDEX")"
  [ -n "$lines" ] || die "session $id is not archived."
  n="$(grep -c . <<<"$lines")"
  if [ "$n" -gt 1 ]; then
    echo "Session $id is archived from $n project folders; pick one with --folder:" >&2
    cut -f1 <<<"$lines" | sed 's/^/  --folder /' >&2
    exit 1
  fi
  IFS="$TAB" read -r fo b by sha <<<"$lines"
  stamps_load_rows
  row="${S_ROW[$fo/$id/$sha]:-}"
  [ -n "$row" ] || die "session $id has no timestamp yet (stamp status shows what is queued)."
  IFS="$TAB" read -r st _ _ b salt leaf _ _ h _ <<<"$row"
  case "$st" in
    complete) ;;
    stamped) echo "Note: this proof is not confirmed in Bitcoin yet (usually a few hours). It will be checkable then; run proof again later for the final one." ;;
    *) die "session $id is $st: its timestamp has not been sent yet. Run stamp now (or stamp backfill)." ;;
  esac
  out="${out:-$PWD/relevio-proof-${id:0:8}}"
  [ ! -e "$out" ] || die "$(relevio_safe "$out") already exists; choose another folder with --out."
  mkdir -p "$out"; chmod 700 "$out"
  j="$PROJECTS/$fo/$id.jsonl"
  if [ -f "$j" ] && [ "$(head -c "$by" "$j" | sha_of)" = "$sha" ]; then
    head -c "$by" "$j" > "$out/conversation.jsonl"
  else
    require_tty
    local idn; idn="$(identity_for "$use" "The conversation is no longer on this machine: opening the archived copy for the proof.")"
    "$AGE" -d -i <(printf '%s\n' "$idn") "$RH/archive/$fo/$b" 2>/dev/null | gzip -dc | tar -xOf - "$id.jsonl" > "$out/conversation.jsonl" \
      || { unset idn; rm -rf "$out"; die "that key could not open the archived conversation."; }
    unset idn
  fi
  chmod 600 "$out/conversation.jsonl"
  printf '%s\n' "$salt" > "$out/salt.txt"
  cp "$STAMP_DIR/$leaf.leaf" "$out/leaf.txt"
  cp "$STAMP_DIR/$leaf.leaf.ots" "$out/leaf.txt.ots"
  if [ "$h" = "$RELEVIO_NONE" ]; then proof_readme "(not confirmed yet: run proof again in a few hours)"; else proof_readme "$h"; fi > "$out/VERIFY.txt"
  echo "Proof folder: $out"
  echo "  conversation.jsonl  the conversation, in clear: it holds EVERYTHING that passed through the tools."
  echo "                      Read it for secrets (keys, passwords) before you share this folder."
  echo "  salt.txt, leaf.txt, leaf.txt.ots, VERIFY.txt  what the other person needs to check it."
  echo "Check it yourself first: $SELF_CMD proof-check $(printf %q "$out")"
}
proof_readme() {
  cat <<EOF
How to check this proof (no trust in the sender needed)
=======================================================

It proves: conversation.jsonl, byte for byte, existed no later than Bitcoin
block $1. It does not prove who wrote it, nor that what it says is true.

1. The conversation matches the stamped leaf. In a terminal, in this folder:

     (printf '%s\n' "\$(cat salt.txt)"; cat conversation.jsonl) | sha256sum

   The result must equal the hex after "salted-sha256" in leaf.txt.
   (One byte changed in the conversation gives a completely different hash.)

2. The leaf is in Bitcoin. Either:
   - open https://opentimestamps.org, choose "Verify", and drop leaf.txt.ots
     and leaf.txt; or
   - with a Bitcoin node: ots verify leaf.txt.ots

   It answers with the block and its time: the latest moment the
   conversation can have been written.
EOF
}
# proof-check <folder>: what VERIFY.txt asks, done here, with two block
# explorers as the Bitcoin source (any one answering is enough; a mismatch
# from any is a failure).
cmd_proof_check() {
  local d="${1:-}" salted want line height merkle api hash got t ok=0 bad=0
  [ -d "$d" ] || die "give the proof folder: proof-check <folder>"
  for f in conversation.jsonl salt.txt leaf.txt leaf.txt.ots; do [ -f "$d/$f" ] || die "$(relevio_safe "$d") has no $f: not a relevio proof folder."; done
  tools_load
  salted="$(salted_of "$(head -1 "$d/salt.txt")" < "$d/conversation.jsonl")"
  want="$(sed -n 's/^salted-sha256 //p' "$d/leaf.txt")"
  [ "$salted" = "$want" ] || die "the conversation does NOT match the stamped leaf: it was changed after it was stamped (or the salt is wrong)."
  echo "1. conversation.jsonl matches the stamped leaf (salted sha256)."
  stamps_load
  [ "$("${OTS_HELPER[@]}" digest "$d/leaf.txt.ots")" = "$(sha_of < "$d/leaf.txt")" ] || die "leaf.txt.ots is the proof of another file, not of leaf.txt."
  "${OTS_HELPER[@]}" attest "$d/leaf.txt.ots" > "$d/.attest" || { rm -f "$d/.attest"; die "leaf.txt.ots is not a readable proof."; }
  line="$(earliest_bitcoin "$d/.attest" leaf.txt.ots)"; rm -f "$d/.attest"
  [ -n "$line" ] || { echo "2. NOT confirmed in Bitcoin yet: the calendars still hold it. Try again in a few hours."; exit 1; }
  read -r height merkle <<<"$line"
  for api in "${EXPLORERS[@]}"; do
    hash="$(curl -fsS --max-time 20 "$api/block-height/$height" 2>/dev/null | grep -E '^[0-9a-f]{64}$' || true)"
    [ -n "$hash" ] || { echo "   $api: no answer"; continue; }
    read -r got t <<<"$(curl -fsS --max-time 20 "$api/block/$hash" 2>/dev/null | jq -r '"\(.merkle_root) \(.timestamp)"' 2>/dev/null || true)"
    if [ "$got" = "$merkle" ]; then ok=$((ok + 1)); echo "   $api: block $height matches (block time $(date -u -d "@$t" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$t"))."
    elif [ -n "$got" ]; then bad=$((bad + 1)); echo "   $api: block $height does NOT match."
    else echo "   $api: no answer"; fi
  done
  [ "$bad" -eq 0 ] || die "a Bitcoin explorer disagrees with the proof: it is not valid."
  [ "$ok" -gt 0 ] || die "no Bitcoin explorer answered (offline?). The proof is not checked yet; try again, or use opentimestamps.org."
  echo "2. The leaf is in Bitcoin block $height: the conversation existed no later than that block."
}
