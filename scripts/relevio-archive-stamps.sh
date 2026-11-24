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
# stamps.tsv: state id folder bundle salt leaf queued_at stamped_at height.
# state: pending (waiting for a batch), stamped (sent, waiting for Bitcoin),
# complete (in a Bitcoin block), needs-key (the transcript is no longer on
# this machine: stamp backfill opens the bundle to compute the leaf).
declare -A S_ROW
stamps_load_rows() {
  local st id fo b salt leaf q s h
  S_ROW=()
  [ -s "$STAMPS_TSV" ] || return 0
  [ "$(head -1 "$STAMPS_TSV")" = "$STAMPS_HEADER" ] || die "$STAMPS_TSV is not a relevio stamp record."
  while IFS="$TAB" read -r st id fo b salt leaf q s h; do
    [ -n "$b" ] && S_ROW["$fo/$b"]="$st$TAB$id$TAB$fo$TAB$b$TAB$salt$TAB$leaf$TAB$q$TAB$s$TAB$h"
  done < <(tail -n +2 "$STAMPS_TSV")
}
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
new_salt() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# --- queue: one leaf per archived generation ------------------------------------------
# The transcript is read from ~/.claude/projects when its first <archived
# bytes> still hash to what was archived (so the leaf is of exactly the
# archived content); otherwise the row waits for stamp backfill.
stamps_queue() {
  local st id fo cwd ver by sha mt fi b bb at j salt salted leaf added=0
  stamps_load_rows
  while IFS="$TAB" read -r st id fo cwd ver by sha mt fi b bb at; do
    [ -n "${S_ROW[$fo/$b]:-}" ] && continue
    j="$PROJECTS/$fo/$id.jsonl"
    if [ "$st" != superseded ] && [ -f "$j" ] && [ "$(head -c "$by" "$j" | sha_of)" = "$sha" ]; then
      salt="$(new_salt)"; salted="$(head -c "$by" "$j" | salted_of "$salt")"
      leaf="$(leaf_write "$salted")"
      S_ROW["$fo/$b"]="pending$TAB$id$TAB$fo$TAB$b$TAB$salt$TAB$leaf$TAB$(date +%s)$TAB$RELEVIO_NONE$TAB$RELEVIO_NONE"
    else
      S_ROW["$fo/$b"]="needs-key$TAB$id$TAB$fo$TAB$b$TAB$RELEVIO_NONE$TAB$RELEVIO_NONE$TAB$(date +%s)$TAB$RELEVIO_NONE$TAB$RELEVIO_NONE"
    fi
    added=$((added + 1))
  done < <(tail -n +2 "$INDEX" 2>/dev/null)
  [ "$added" -eq 0 ] || stamps_save_rows
}

# --- batch and upgrade ---------------------------------------------------------------
stamps_status_write() {  # <ok|fail> <message>
  { echo "state $1"; echo "at $(date +%s)"; echo "message $(printf '%s' "${2:-}" | tr '\n\t' '  ' | cut -c1-200)"; } > "$RH/stamps.status.tmp"
  mv "$RH/stamps.status.tmp" "$RH/stamps.status"
}
stamps_status_field() { [ -r "$RH/stamps.status" ] || return 0; sed -n "s/^$1 //p" "$RH/stamps.status" | head -1; }
STAMP_ERR=""
# stamps_batch <force|auto>: sends every pending leaf in one client call.
stamps_batch() {
  local k st q now oldest="" n=0 last err
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
    last="$(config_get stamp_last_try)"
    [ -z "$last" ] || [ $((now - last)) -ge "$STAMP_RETRY" ] || return 0
  fi
  config_set stamp_last_try "$now"
  # At least 2 calendars must answer (measured: with one down the proof is
  # still made from the others; with none, the client fails and writes nothing).
  if ! err="$("$OTS_BIN" -q stamp -m 2 "${files[@]}" 2>&1)"; then
    STAMP_ERR="no timestamp calendar answered ($(printf '%s' "$err" | tail -1 | tr -c 'A-Za-z0-9 ._:-' ' ' | cut -c1-120)); the $n leaf(s) stay queued"
    return 1
  fi
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st id fo b salt leaf q _ h <<<"${S_ROW[$k]}"
    [ "$st" = pending ] && [ -s "$STAMP_DIR/$leaf.leaf.ots" ] || continue
    S_ROW["$k"]="stamped$TAB$id$TAB$fo$TAB$b$TAB$salt$TAB$leaf$TAB$q$TAB$now$TAB$h"
  done
  log "stamps: $n leaf(s) sent to the calendars"
}
# stamps_upgrade <force|auto>: asks the calendars for the Bitcoin part of
# every proof sent at least an hour ago. A proof still pending stays stamped.
stamps_upgrade() {
  local k st id fo b salt leaf q s h now line n=0 done_n=0
  local -a files=()
  now="$(date +%s)"
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st _ _ _ _ leaf _ s _ <<<"${S_ROW[$k]}"
    [ "$st" = stamped ] || continue
    [ "$1" = force ] || [ $((now - s)) -ge "$STAMP_UPGRADE_AFTER" ] || continue
    files+=("$STAMP_DIR/$leaf.leaf.ots"); n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 0
  # Exit status is not success while any proof is still waiting: read each.
  "$OTS_BIN" -q upgrade "${files[@]}" >/dev/null 2>&1 || true
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st id fo b salt leaf q s h <<<"${S_ROW[$k]}"
    [ "$st" = stamped ] || continue
    line="$("${OTS_HELPER[@]}" attest "$STAMP_DIR/$leaf.leaf.ots" 2>/dev/null | grep '^bitcoin ' | sort -k2,2n | head -1 || true)"
    [ -n "$line" ] || continue
    read -r _ h _ <<<"$line"
    S_ROW["$k"]="complete$TAB$id$TAB$fo$TAB$b$TAB$salt$TAB$leaf$TAB$q$TAB$s$TAB$h"
    done_n=$((done_n + 1))
  done
  [ "$done_n" -eq 0 ] || log "stamps: $done_n proof(s) confirmed in Bitcoin"
}
# After every archiving run (lock held). Never fails the run: the stamp
# status says what went wrong.
stamp_after_run() {
  stamping_on || return 0
  ( stamps_load; stamps_queue
    if stamps_batch auto; then stamps_upgrade auto; stamps_save_rows; stamps_status_write ok ""
    else stamps_save_rows; stamps_status_write fail "$STAMP_ERR"; log "stamps: $STAMP_ERR"; fi ) 2>"$RH/.stamp.err" \
    || { stamps_status_write fail "stamping did not run: $(sed 's/^ERROR: //' "$RH/.stamp.err" | tail -1 | cut -c1-150)"; log "stamps: did not run"; }
  rm -f "$RH/.stamp.err"
  return 0
}

# --- commands ------------------------------------------------------------------------------
cmd_stamp() {
  local sub="${1:-}"; shift || true
  check_writable; is_set_up || die "the archive is not set up in $RH: run setup first."
  load_config; SHA="$(sha_tool)" || die "no sha256 tool found."
  case "$sub" in
    setup) stamp_setup ;;
    status) stamp_show ;;
    now) stamp_now ;;
    backfill) stamp_backfill ;;
    off) config_unset stamping; echo "Timestamping is off. Proofs already made stay valid and stay in $STAMP_DIR." ;;
    *) die "stamp needs: setup | status | now | backfill | off" ;;
  esac
}
# The client lives in its own virtual environment inside the archive home,
# pinned to a version published long ago (this machine's package cooldown).
stamp_setup() {
  local venv="$RH/ots-venv" py
  if [ -n "$TEST_OTS_BIN" ]; then
    config_set ots_venv "$venv"; config_set stamping on; echo "Timestamping is on (test client)."; return 0
  fi
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
  config_set ots_venv "$venv"; config_set stamping on
  echo "Timestamping is on. Every archived conversation is stamped within a day;"
  echo "Bitcoin confirms each batch a few hours later. Stamp what is queued now with: bash \"$SELF\" stamp now"
}
stamp_now() {
  stamping_on || die "timestamping is off: run stamp setup first."
  trap release_lock EXIT
  take_lock wait || die "an archiving run holds the lock; try again in a minute."
  stamps_load; stamps_queue
  if ! stamps_batch force; then stamps_save_rows; stamps_status_write fail "$STAMP_ERR"; die "$STAMP_ERR. Nothing is lost: they are sent next time."; fi
  stamps_upgrade force; stamps_save_rows; stamps_status_write ok ""
  stamp_show
}
stamp_show() {
  local st c n p s k nk
  if ! stamping_on; then echo "stamps: off. Turn on with: stamp setup"; return 0; fi
  stamps_load_rows
  declare -A C=([pending]=0 [stamped]=0 [complete]=0 [needs-key]=0)
  for k in "${!S_ROW[@]}"; do st="${S_ROW[$k]%%$TAB*}"; C[$st]=$(( ${C[$st]:-0} + 1 )); done
  echo "stamps: ${C[complete]} proven in Bitcoin, ${C[stamped]} waiting for Bitcoin, ${C[pending]} queued for the next batch"
  [ "${C[needs-key]}" -eq 0 ] || echo "  ${C[needs-key]} need a key: their transcript is gone from this machine. Run in your terminal: bash \"$SELF\" stamp backfill"
  [ "$(stamps_status_field state)" = fail ] && echo "  last try FAILED: $(relevio_safe "$(stamps_status_field message)")"
  return 0
}
# Rows whose transcript is gone: open each bundle (user's terminal, a key)
# and compute the leaf from what was archived.
stamp_backfill() {
  local use=main idn k st id fo b tmp n=0 salt salted leaf
  [ "${1:-}" = --recovery ] && use=recovery
  require_tty; stamping_on || die "timestamping is off: run stamp setup first."
  trap 'rm -rf "${STAMP_TMP:-}"; release_lock' EXIT
  take_lock wait || die "an archiving run holds the lock; try again in a minute."
  stamps_queue
  for k in "${!S_ROW[@]}"; do [ "${S_ROW[$k]%%$TAB*}" = needs-key ] && n=$((n + 1)); done
  [ "$n" -gt 0 ] || { echo "Nothing needs a key: every archived conversation has its leaf."; return 0; }
  echo "$n archived conversation(s) are no longer on this machine; opening them to compute their leaf (nothing is written in clear outside a private temporary folder)."
  idn="$(identity_for "$use" "Opening archived conversations to timestamp them.")"
  STAMP_TMP="$(mktemp -d "$RH/.stamp.XXXXXX")"; tmp="$STAMP_TMP"
  n=0
  for k in "${!S_ROW[@]}"; do
    IFS="$TAB" read -r st id fo b _ <<<"${S_ROW[$k]}"
    [ "$st" = needs-key ] || continue
    index_names_ok "$id" "$fo" "$b" || continue
    "$AGE" -d -i <(printf '%s\n' "$idn") "$RH/archive/$fo/$b" 2>/dev/null | gzip -dc | tar -xf - -C "$tmp" "$id.jsonl" 2>/dev/null \
      || { log "stamp backfill: could not open $fo/$b"; continue; }
    salt="$(new_salt)"; salted="$(salted_of "$salt" < "$tmp/$id.jsonl")"; rm -f "$tmp/$id.jsonl"
    leaf="$(leaf_write "$salted")"
    S_ROW["$k"]="pending$TAB$id$TAB$fo$TAB$b$TAB$salt$TAB$leaf$TAB$(date +%s)$TAB$RELEVIO_NONE$TAB$RELEVIO_NONE"
    n=$((n + 1))
  done
  unset idn
  stamps_save_rows
  echo "Done: $n leaf(s) computed; they go out in the next batch (or now: stamp now)."
}

# --- proof: the folder a colleague, an auditor or a court can check ---------------------------
cmd_proof() {
  local id="${1:-}" out="" use=main fo b st salt leaf h row k j by sha tmp
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in --out) out="${2:-}"; shift 2 ;; --recovery) use=recovery; shift ;; *) die "unknown proof option '$(relevio_safe "$1")'" ;; esac
  done
  check_home; is_set_up || die "the archive is not set up in $RH."
  load_config; SHA="$(sha_tool)" || die "no sha256 tool found."
  [[ $id =~ $SESSION_RE ]] || die "'$(relevio_safe "$id")' is not a session id."
  stamps_load_rows
  # The current generation of the session (its bundle is <id>.tgz.age).
  row=""
  for k in "${!S_ROW[@]}"; do
    case "$k" in */"$id.tgz.age") row="${S_ROW[$k]}"; break ;; esac
  done
  [ -n "$row" ] || die "session $id has no timestamp yet (stamp status shows what is queued)."
  IFS="$TAB" read -r st _ fo b salt leaf _ _ h <<<"$row"
  case "$st" in
    complete) ;;
    stamped) echo "Note: this proof is not confirmed in Bitcoin yet (usually a few hours). It will be checkable then; run proof again later for the final one." ;;
    *) die "session $id is $st: its timestamp has not been sent yet. Run stamp now (or stamp backfill)." ;;
  esac
  out="${out:-$PWD/relevio-proof-${id:0:8}}"
  [ ! -e "$out" ] || die "$(relevio_safe "$out") already exists; choose another folder with --out."
  mkdir -p "$out"; chmod 700 "$out"
  read -r by sha <<<"$(awk -F'\t' -v f="$fo" -v b="$b" 'NR > 1 && $3 == f && $10 == b { print $6, $7; exit }' "$INDEX")"
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
  echo "Check it yourself first: bash \"$SELF\" proof-check \"$out\""
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
  SHA="$(sha_tool)" || die "no sha256 tool found."
  load_config
  salted="$(salted_of "$(head -1 "$d/salt.txt")" < "$d/conversation.jsonl")"
  want="$(sed -n 's/^salted-sha256 //p' "$d/leaf.txt")"
  [ "$salted" = "$want" ] || die "the conversation does NOT match the stamped leaf: it was changed after it was stamped (or the salt is wrong)."
  echo "1. conversation.jsonl matches the stamped leaf (salted sha256)."
  stamps_load
  [ "$("${OTS_HELPER[@]}" digest "$d/leaf.txt.ots")" = "$(sha_of < "$d/leaf.txt")" ] || die "leaf.txt.ots is the proof of another file, not of leaf.txt."
  line="$("${OTS_HELPER[@]}" attest "$d/leaf.txt.ots" | grep '^bitcoin ' | sort -k2,2n | head -1 || true)"
  [ -n "$line" ] || { echo "2. NOT confirmed in Bitcoin yet: the calendars still hold it. Try again in a few hours."; exit 1; }
  read -r _ height merkle <<<"$line"
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
