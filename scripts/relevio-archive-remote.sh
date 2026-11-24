# relevio archive: the copy off this machine. Sourced by relevio-archive.sh,
# never run on its own; it uses that script's helpers (RH, AGE, SHA, log,
# die, the lock, the index).
#
# What leaves the machine is encrypted, names included: bundles travel under
# opaque names, and the index, the folder cache and the upload records travel
# as ONE encrypted catalog. Locally those files stay plain (they show nothing
# that ~/.claude/projects does not already show in clear).
#
# Layout of the copy, under the target the user chose:
#   README.txt                          plain: what this folder is
#   machines/<machine>/b/<opaque>.age   one bundle, the same bytes as locally
#   machines/<machine>/keys/main.age    the main key, locked by the passphrase
#   machines/<machine>/keys/recipients.txt  public keys only
#   machines/<machine>/catalog.age      index + folders + forgotten + uploads
#
# Two transports with one code path: a folder that a sync client mirrors
# (Google Drive for desktop, Dropbox, OneDrive, Syncthing, a NAS), or rclone,
# which talks to the provider itself. Only the t_* functions differ.

REMOTE_TSV="$RH/remote.tsv"
REMOTE_HEADER="#relevio-remote	1"
CATALOG_FORMAT=1
RCLONE_OPTS=(--retries 2 --low-level-retries 3 --contimeout 15s --timeout 60s)

# --- config ------------------------------------------------------------------------
config_set() {  # <key> <value>: one line per key, rewritten through a temp file
  KEY="$1" VAL="$2" awk -F= -v OFS== '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
    $1 == k { if (!done) print k, v; done = 1; next }
    { print }
    END { if (!done) print k, v }' "$RH/config" > "$RH/config.tmp"
  mv "$RH/config.tmp" "$RH/config"
}
config_unset() { KEY="$1" awk -F= '$1 != ENVIRON["KEY"]' "$RH/config" > "$RH/config.tmp"; mv "$RH/config.tmp" "$RH/config"; }
remote_is_set() { [ -n "$(config_get remote_kind)" ]; }
# Sets R_KIND, R_TARGET, R_BASE (this machine's folder in the copy), RCLONE.
remote_load() {
  R_KIND="$(config_get remote_kind)"; R_TARGET="$(config_get remote_target)"
  local m; m="$(config_get machine)"
  [ -n "$R_KIND" ] || die "no off-machine copy is set. Set one with: bash \"$SELF\" remote set folder <path> (or rclone <remote:path>)."
  [[ $m =~ ^[0-9a-f]{12}$ ]] || die "$RH/config has no valid machine id; run remote set again."
  R_BASE="$R_TARGET/machines/$m"
  if [ "$R_KIND" = rclone ]; then
    RCLONE="$(config_get rclone)"
    [ -n "$RCLONE" ] && [ -x "$RCLONE" ] || die "rclone is missing at '$(relevio_safe "$RCLONE")': install it (sudo apt install rclone) and run remote set again."
  fi
}

# --- transports ----------------------------------------------------------------------
# Every t_* call either succeeds or returns 1 with R_ERR set to a one-line
# reason the user can act on. rclone's exit codes do not tell a lost login from
# a lost network (measured: both exit 1), so the reason comes from its message.
R_ERR=""
rclone_reason() {  # stdin: rclone's stderr
  local e; e="$(cat)"
  case "$e" in
    *"couldn't fetch token"*|*invalid_grant*|*"token expired"*)
      R_ERR="the login to ${R_TARGET%%:*} expired: run in your terminal: rclone config reconnect ${R_TARGET%%:*}:" ;;
    *storageQuotaExceeded*|*"quota"*|*"Quota"*) R_ERR="the cloud storage is full: quota exceeded" ;;
    *"dial tcp"*|*"no such host"*|*"connection refused"*|*"i/o timeout"*|*"network is unreachable"*|*"TLS handshake timeout"*)
      R_ERR="no connection to the cloud: offline, or the provider is down" ;;
    *"directory not found"*|*"object not found"*|*"file not found"*) R_ERR="not found in the copy" ;;
    *) R_ERR="rclone failed: $(printf '%s' "$e" | tail -1 | relevio_safe_stdin | cut -c1-160)" ;;
  esac
}
relevio_safe_stdin() { tr -c 'A-Za-z0-9._/:() -' '?'; }
target_safe() { printf '%s' "$1" | relevio_safe_stdin; }
rc() {  # run rclone, R_ERR on failure
  local err
  if err="$("$RCLONE" "${RCLONE_OPTS[@]}" "$@" 2>&1 >/dev/null)"; then return 0; fi
  rclone_reason <<<"$err"; return 1
}
rc_to() {  # <out file> <rclone args>: stdout into the file, R_ERR on failure.
  # Never called inside $( ): R_ERR set in a subshell would be lost.
  local o="$1"; shift
  if "$RCLONE" "${RCLONE_OPTS[@]}" "$@" > "$o" 2>"$RH/.rclone.err"; then rm -f "$RH/.rclone.err"; return 0; fi
  rclone_reason < "$RH/.rclone.err"; rm -f "$RH/.rclone.err"; return 1
}
folder_ok() {
  [ -d "$R_TARGET" ] || { R_ERR="the folder $(target_safe "$R_TARGET") is gone: is the drive or the sync client mounted"; return 1; }
}
# t_put <local file> <relative path>: atomic, through <path>.part.
t_put() {
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      mkdir -p "$(dirname "$R_BASE/$2")" && cp "$1" "$R_BASE/$2.part" && mv "$R_BASE/$2.part" "$R_BASE/$2" \
        || { R_ERR="could not write into $(target_safe "$R_TARGET"): disk full or no permission"; return 1; } ;;
    rclone)
      rc copyto "$1" "$R_BASE/$2.part" && rc moveto "$R_BASE/$2.part" "$R_BASE/$2" ;;
  esac
}
# t_put_dir <local dir of files or symlinks> <relative dir>: many files at once.
# rclone runs them in parallel; a cut upload leaves nothing behind on Drive
# (measured), and a partial file elsewhere fails the md5 check that follows.
t_put_dir() {
  local f
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      mkdir -p "$R_BASE/$2" || { R_ERR="could not write into $(target_safe "$R_TARGET")"; return 1; }
      for f in "$1"/*; do
        [ -e "$f" ] || continue
        cp -L "$f" "$R_BASE/$2/${f##*/}.part" && mv "$R_BASE/$2/${f##*/}.part" "$R_BASE/$2/${f##*/}" \
          || { R_ERR="could not write into $(target_safe "$R_TARGET"): disk full or no permission"; return 1; }
      done ;;
    rclone) rc copy --copy-links --transfers 8 "$1" "$R_BASE/$2" ;;
  esac
}
t_get() {  # <relative path> <local file>
  case "$R_KIND" in
    folder) folder_ok || return 1; [ -f "$R_BASE/$1" ] || { R_ERR="not found in the copy"; return 1; }; cp "$R_BASE/$1" "$2" ;;
    rclone) rc copyto "$R_BASE/$1" "$2" ;;
  esac
}
# t_md5 <relative dir>: "<md5> <name>" per file. Drive answers it from its own
# records, so every bundle is checked without downloading one.
t_md5() {
  local f
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      [ -d "$R_BASE/$1" ] || return 0
      for f in "$R_BASE/$1"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.part) continue ;; esac
        printf '%s %s\n' "$(md5_of < "$f")" "${f##*/}"
      done ;;
    rclone)
      if ! rc_to "$RH/.rclone.out" hashsum md5 "$R_BASE/$1"; then
        rm -f "$RH/.rclone.out"; [ "$R_ERR" = "not found in the copy" ] && return 0; return 1
      fi
      awk '$2 !~ /\.part$/ { print $1, $2 }' "$RH/.rclone.out"; rm -f "$RH/.rclone.out" ;;
  esac
}
# t_md5_all: "<md5> <relative path>" for every file of this machine's copy
# (bundles, keys, catalog), in one listing call.
t_md5_all() {
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      [ -d "$R_BASE" ] || return 0
      local f
      while IFS= read -r -d '' f; do
        case "$f" in *.part) continue ;; esac
        printf '%s %s\n' "$(md5_of < "$f")" "${f#"$R_BASE/"}"
      done < <(find "$R_BASE" -type f -print0) ;;
    rclone)
      if ! rc_to "$RH/.rclone.out" hashsum md5 "$R_BASE"; then
        rm -f "$RH/.rclone.out"; [ "$R_ERR" = "not found in the copy" ] && return 0; return 1
      fi
      awk '$2 !~ /\.part$/ { print $1, $2 }' "$RH/.rclone.out"; rm -f "$RH/.rclone.out" ;;
  esac
}
t_delete() {  # <relative path>; a file already gone is fine
  case "$R_KIND" in
    folder) folder_ok || return 1; rm -f "$R_BASE/$1" ;;
    rclone) rc deletefile "$R_BASE/$1" || [ "$R_ERR" = "not found in the copy" ] ;;
  esac
}
t_list_machines() {
  case "$R_KIND" in
    folder) folder_ok || return 1; [ -d "$R_TARGET/machines" ] || return 0; find "$R_TARGET/machines" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' ;;
    rclone)
      if ! rc_to "$RH/.rclone.out" lsf --dirs-only "$R_TARGET/machines"; then
        rm -f "$RH/.rclone.out"; [ "$R_ERR" = "not found in the copy" ] && return 0; return 1
      fi
      sed 's|/$||' "$RH/.rclone.out"; rm -f "$RH/.rclone.out" ;;
  esac
}
md5_of() { if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{ print $1 }'; else md5 -q; fi; }

# --- upload records ------------------------------------------------------------------
# remote.tsv: opaque folder bundle bytes mtime sha256 md5 uploaded_at, one row
# per bundle in the copy. A bundle is re-sent when its bytes or mtime change
# (keys rotate-recovery rewrites every bundle in place).
opaque_of() { printf '%s/%s/%s' "$(config_get copy_salt)" "$1" "$2" | sha_of | cut -c1-32; }
declare -A U_ROW U_KEY
# The opaque name of folder/bundle: from the records when known (one sha256
# process per bundle is too slow for every run), computed otherwise.
opaque_for() { local k="$1/$2"; if [ -n "${U_KEY[$k]:-}" ]; then printf '%s' "${U_KEY[$k]}"; else opaque_of "$1" "$2"; fi; }
remote_records_load() {
  local o f b by mt sh m at
  U_ROW=(); U_KEY=()
  [ -s "$REMOTE_TSV" ] || return 0
  [ "$(head -1 "$REMOTE_TSV")" = "$REMOTE_HEADER" ] || die "$REMOTE_TSV is not a relevio upload record."
  while IFS="$TAB" read -r o f b by mt sh m at; do
    [ -n "$o" ] || continue
    U_ROW["$o"]="$f$TAB$b$TAB$by$TAB$mt$TAB$sh$TAB$m$TAB$at"; U_KEY["$f/$b"]="$o"
  done < <(tail -n +2 "$REMOTE_TSV")
}
remote_records_save() {
  local o
  { printf '%s\n' "$REMOTE_HEADER"
    for o in "${!U_ROW[@]}"; do printf '%s\t%s\n' "$o" "${U_ROW[$o]}"; done | sort -t"$TAB" -k2,3; } > "$REMOTE_TSV.tmp"
  mv "$REMOTE_TSV.tmp" "$REMOTE_TSV"
}

# --- status of the copy --------------------------------------------------------------------
remote_status_write() {  # <ok|behind|fail> <message>
  { echo "state $1"; echo "at $(date +%s)"; echo "message $(printf '%s' "${2:-}" | tr '\n\t' '  ' | cut -c1-200)"; } > "$RH/remote.status.tmp"
  mv "$RH/remote.status.tmp" "$RH/remote.status"
}
remote_status_field() { [ -r "$RH/remote.status" ] || return 0; sed -n "s/^$1 //p" "$RH/remote.status" | head -1; }

# --- push --------------------------------------------------------------------------------
# Every bundle the index names (current, older generations, deleted in
# Claude), then the keys, then the catalog LAST: a catalog in the copy never
# names a bundle that is not there. Called with the lock held.
PUSH_SENT=0; PUSH_PENDING=0
push_core() {  # [limit]
  local limit="${1:-0}" st fo b f by mt o row stage sh m n=0 changed=0 rby rmt rm5
  remote_load; remote_records_load
  stage="$(mktemp -d "$RH/.push.XXXXXX")"; PUSH_STAGE="$stage"
  declare -A WANT=() NEW_ROW=() GOT=()
  # What the copy really holds (one listing call): a bundle, a key or a
  # catalog missing or altered there is sent again, whatever the records say.
  local gm gn
  declare -A ALL=()
  # (into a file, not a pipe: R_ERR must survive, and a pipe is a subshell)
  t_md5_all > "$RH/.push.md5" || { rm -rf "$stage"; return 1; }
  while read -r gm gn; do
    [ -n "$gn" ] || continue
    ALL["$gn"]="$gm"
    case "$gn" in b/*.age) gn="${gn#b/}"; GOT["${gn%.age}"]="$gm" ;; esac
  done < "$RH/.push.md5"
  while IFS="$TAB" read -r st _ fo _ _ _ _ _ _ b _; do
    f="$RH/archive/$fo/$b"
    [ -f "$f" ] || { log "push: $fo/$b is in the index but missing on disk; not sent"; continue; }
    read -r by mt <<<"$(file_stat "$f")"
    o="$(opaque_for "$fo" "$b")"; WANT["$o"]=1
    row="${U_ROW[$o]:-}"
    if [ -n "$row" ]; then
      IFS="$TAB" read -r _ _ rby rmt _ rm5 _ <<<"$row"
      [ "$rby" = "$by" ] && [ "$rmt" = "$mt" ] && [ "${GOT[$o]:-}" = "$rm5" ] && continue
    fi
    if [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ]; then PUSH_PENDING=$((PUSH_PENDING + 1)); continue; fi
    sh="$(sha_of < "$f")"; m="$(md5_of < "$f")"
    ln -s "$f" "$stage/$o.age"
    NEW_ROW["$o"]="$fo$TAB$b$TAB$by$TAB$mt$TAB$sh$TAB$m$TAB$(utc_iso)"
    n=$((n + 1))
  done < <(tail -n +2 "$INDEX" 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    t_put_dir "$stage" b || { rm -rf "$stage"; return 1; }
    # Proof the copy holds what was sent: the provider's md5 of each file.
    GOT=()
    t_md5 b > "$RH/.push.md5" || { rm -rf "$stage"; return 1; }
    while read -r gm gn; do [ -n "$gn" ] && GOT["${gn%.age}"]="$gm"; done < "$RH/.push.md5"
    for o in "${!NEW_ROW[@]}"; do
      IFS="$TAB" read -r _ _ _ _ _ m _ <<<"${NEW_ROW[$o]}"
      if [ "${GOT[$o]:-}" != "$m" ]; then R_ERR="the copy of a bundle does not match what was sent by md5; it is sent again next time"; rm -rf "$stage"; return 1; fi
      U_ROW["$o"]="${NEW_ROW[$o]}"
    done
    PUSH_SENT=$n; changed=1
    remote_records_save
  fi
  # A bundle leaves the copy only when its session was forgotten on
  # purpose. Anything else missing from the index (a damaged or emptied
  # index) is never a reason to delete: it is logged and kept.
  forgotten_load
  for o in "${!U_ROW[@]}"; do
    [ -n "${WANT[$o]:-}" ] && continue
    IFS="$TAB" read -r _ b _ <<<"${U_ROW[$o]}"
    if [ -n "${FORGOTTEN[${b:0:36}]:-}" ]; then
      t_delete "b/$o.age" || { rm -rf "$stage"; return 1; }
      unset "U_ROW[$o]"; changed=1
    else
      log "push: $b is in the copy but not in the index; kept (only forget removes from the copy)"
    fi
  done
  [ "$changed" = 1 ] && remote_records_save
  # Keys: sent when they change (a passphrase change rewrites main.age).
  for f in main.age recipients.txt; do
    [ -f "$RH/keys/$f" ] || continue
    sh="$(sha_of < "$RH/keys/$f")"
    [ "$(config_get "sent_$f")" = "$sh" ] && [ "${ALL[keys/$f]:-}" = "$(md5_of < "$RH/keys/$f")" ] && continue
    t_put "$RH/keys/$f" "keys/$f" || { rm -rf "$stage"; return 1; }
    config_set "sent_$f" "$sh"; changed=1
  done
  # The catalog is rewritten when anything changed, and also when the one in
  # the copy is not the last one this machine wrote (replaced, rolled back,
  # deleted).
  if [ "$changed" = 1 ] || [ -z "$(config_get catalog_seq)" ] || [ "${ALL[catalog.age]:-}" != "$(config_get catalog_md5)" ]; then
    catalog_build "$stage/catalog.age" || { rm -rf "$stage"; return 1; }
    t_put "$stage/catalog.age" catalog.age || { rm -rf "$stage"; return 1; }
    config_set catalog_sha "$(sha_of < "$stage/catalog.age")"; config_set catalog_md5 "$(md5_of < "$stage/catalog.age")"
  fi
  [ "$(config_get readme_sent)" = 1 ] || { readme_write "$stage/README.txt"; readme_put "$stage/README.txt" && config_set readme_sent 1; }
  rm -rf "$stage" "$RH/.push.md5"; PUSH_STAGE=""
  return 0
}
# The catalog: everything a new machine needs to know what the copy holds,
# encrypted to the same keys as the bundles. Its sequence number lets a new
# machine see how recent it is; this machine keeps the sha of the last one it
# wrote, so a swapped catalog in the copy is caught by verify.
catalog_build() {  # <out file>
  local d seq
  seq="$(config_get catalog_seq)"; seq=$(( ${seq:-0} + 1 ))
  d="$(mktemp -d "$RH/.catalog.XXXXXX")"
  { echo "relevio-catalog $CATALOG_FORMAT"; echo "seq $seq"; echo "machine $(config_get machine)"
    echo "copy_salt $(config_get copy_salt)"; echo "written $(utc_iso)"; echo "relevio_version $(relevio_version)"; } > "$d/META"
  for f in index.tsv folders.tsv forgotten.tsv remote.tsv; do [ -f "$RH/$f" ] && cp "$RH/$f" "$d/$f"; done
  tar -cf - -C "$d" . | gzip -c | "$AGE" -e -R "$RH/keys/recipients.txt" -o "$1" || { rm -rf "$d"; R_ERR="could not encrypt the catalog"; return 1; }
  rm -rf "$d"
  config_set catalog_seq "$seq"
}
readme_write() {
  cat > "$1" <<'EOF'
This folder is an encrypted copy of Claude Code conversations, made by relevio
(https://github.com/compota334/relevio).

Everything under machines/ is encrypted with age, names included: without the
owner's passphrase or recovery key nothing here can be read. To bring it back
on a new computer, install relevio and run, in your own terminal:

    bash .claude/scripts/relevio-archive.sh pull folder <this folder>
    (or: ... pull rclone <remote:path>)

Do not rename or edit the files here.
EOF
}
readme_put() {
  case "$R_KIND" in
    folder) folder_ok && cp "$1" "$R_TARGET/README.txt" ;;
    rclone) rc copyto "$1" "$R_TARGET/README.txt" ;;
  esac
}
# After every archiving run (lock held): send what is new. A failure never
# fails the archiving run; the copy's status says it, loudly.
push_after_run() {
  remote_is_set || return 0
  # A subshell, so a die inside (rclone gone, a bad config) ends only the
  # copy and leaves the archiving run's own result alone.
  ( PUSH_SENT=0; PUSH_PENDING=0; R_ERR=""
    if push_core 0; then remote_status_write ok "sent $PUSH_SENT"
    else remote_status_write fail "$R_ERR"; log "push: $R_ERR"; fi ) 2>"$RH/.push.err" \
    || { remote_status_write fail "the copy did not run: $(sed 's/^ERROR: //' "$RH/.push.err" | tail -1 | cut -c1-150)"; log "push: did not run"; }
  rm -f "$RH/.push.err"
  return 0
}

# --- commands ------------------------------------------------------------------------------
cmd_remote() {
  local sub="${1:-}"; shift || true
  check_writable; is_set_up || die "the archive is not set up in $RH: run setup first."
  load_config; SHA="$(sha_tool)" || die "no sha256 tool found."
  case "$sub" in
    set) remote_set "$@" ;;
    status) remote_show ;;
    off)
      remote_is_set || { echo "No off-machine copy is set."; return 0; }
      for k in remote_kind remote_target rclone catalog_seq catalog_sha catalog_md5 sent_main.age sent_recipients.txt readme_sent; do config_unset "$k"; done
      rm -f "$REMOTE_TSV" "$RH/remote.status"
      echo "The off-machine copy is no longer updated. What is already there stays; delete it from the provider yourself if you want it gone." ;;
    *) die "remote needs: set folder <path> | set rclone <remote:path> | status | off" ;;
  esac
}
remote_set() {
  local kind="${1:-}" target="${2:-}" r
  [ $# -eq 2 ] || die "remote set needs: folder <path>, or rclone <remote:path>."
  case "$kind" in
    folder)
      [ -d "$target" ] || die "'$(target_safe "$target")' is not a folder. Create it (or let the sync client create it) first."
      target="$(cd "$target" && pwd -P)"
      case "$target/" in "$(cd "$RH" && pwd -P)/"*) die "the copy cannot live inside the archive itself." ;; esac
      git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 && die "'$(target_safe "$target")' is inside a git repository: the copy must never be one commit away from a push."
      [ -w "$target" ] || die "'$(target_safe "$target")' is not writable." ;;
    rclone)
      r="$(command -v rclone)" || die "rclone is not installed: sudo apt install rclone (Linux) or see https://rclone.org/install/"
      case "$target" in *:*) ;; *) die "an rclone target looks like <remote>:<path>, for example relevio-gdrive:relevio" ;; esac
      RCLONE="$r"; R_TARGET="$target"
      echo "Checking access to $(target_safe "$target")..."
      rc mkdir "$target" || die "$R_ERR"
      config_set rclone "$r" ;;
    *) die "remote set needs: folder <path>, or rclone <remote:path>." ;;
  esac
  [ -n "$(config_get machine)" ] || config_set machine "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ -n "$(config_get copy_salt)" ] || config_set copy_salt "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  config_set remote_kind "$kind"; config_set remote_target "$target"
  for k in catalog_seq catalog_sha catalog_md5 sent_main.age sent_recipients.txt readme_sent; do config_unset "$k"; done
  rm -f "$REMOTE_TSV" "$RH/remote.status"
  echo "Off-machine copy set: $kind $(target_safe "$target")."
  echo "Every bundle, the keys and an encrypted catalog go there; names are opaque."
  echo "Send everything now with: bash \"$SELF\" push   (later runs send only what is new)"
}
remote_show() {
  remote_is_set || { echo "copy: none set. Set one with: remote set folder <path> | remote set rclone <remote:path>"; return 0; }
  remote_load
  local st at n b
  st="$(remote_status_field state)"; at="$(remote_status_field at)"
  case "$at" in ""|*[!0-9]*) at=0 ;; esac
  echo "copy: $R_KIND $(target_safe "$R_TARGET") (this machine: $(config_get machine))"
  n=0; [ -s "$REMOTE_TSV" ] && n=$(( $(grep -c . "$REMOTE_TSV") - 1 ))
  echo "  sent: $n bundle(s); catalog #$(config_get catalog_seq || true)"
  case "$st" in
    "") echo "  last push: none yet (run push)" ;;
    ok) echo "  last push: ok, $(fmt_time "$at")" ;;
    *) echo "  last push: FAILING since $(fmt_time "$at"): $(relevio_safe "$(remote_status_field message)")" ;;
  esac
  b="$(remote_behind)"
  [ "$b" -eq 0 ] || echo "  behind: $b bundle(s) not in the copy yet"
}
remote_behind() {
  local n=0 st fo b by mt o row rby rmt
  remote_records_load
  while IFS="$TAB" read -r st _ fo _ _ _ _ _ _ b _; do
    [ -f "$RH/archive/$fo/$b" ] || continue
    read -r by mt <<<"$(file_stat "$RH/archive/$fo/$b")"
    o="$(opaque_for "$fo" "$b")"; row="${U_ROW[$o]:-}"
    if [ -z "$row" ]; then n=$((n + 1)); continue; fi
    IFS="$TAB" read -r _ _ rby rmt _ <<<"$row"
    [ "$rby" = "$by" ] && [ "$rmt" = "$mt" ] || n=$((n + 1))
  done < <(tail -n +2 "$INDEX" 2>/dev/null)
  echo "$n"
}
cmd_push() {
  local limit=0
  case "${1:-}" in --limit) limit="${2:-}"; [[ $limit =~ ^[1-9][0-9]*$ ]] || die "--limit needs a positive number." ;; "") ;; *) die "push takes only --limit <n>." ;; esac
  check_writable; is_set_up || die "the archive is not set up in $RH."
  load_config; SHA="$(sha_tool)" || die "no sha256 tool found."
  remote_is_set || die "no off-machine copy is set: remote set folder <path> | remote set rclone <remote:path>"
  trap 'rm -rf "${PUSH_STAGE:-}"; release_lock' EXIT
  take_lock wait || die "an archiving run holds the lock; try again in a minute."
  echo "Sending to the copy ($(target_safe "$(config_get remote_target)"))..."
  if push_core "$limit"; then
    remote_status_write ok "sent $PUSH_SENT"
    echo "Done: $PUSH_SENT bundle(s) sent, catalog #$(config_get catalog_seq)."
    [ "$PUSH_PENDING" -eq 0 ] || echo "$PUSH_PENDING more left (--limit); run push again."
  else
    remote_status_write fail "$R_ERR"; log "push: $R_ERR"
    die "$R_ERR. Nothing is lost: what was not sent is sent next time."
  fi
}
# verify: path 1, the provider's md5 of EVERY bundle against what was sent
# (nothing downloaded); path 2, a random sample downloaded and checked by
# sha256; plus the catalog this machine wrote last. No secret needed.
cmd_verify() {
  local sample=3 o row m sh fo b bad=0 miss=0 n=0 tmp got
  case "${1:-}" in --sample) sample="${2:-}"; [[ $sample =~ ^[0-9]+$ ]] || die "--sample needs a number." ;; "") ;; *) die "verify takes only --sample <n>." ;; esac
  check_home; is_set_up || die "the archive is not set up in $RH."
  load_config; SHA="$(sha_tool)" || die "no sha256 tool found."
  remote_load; remote_records_load
  [ "${#U_ROW[@]}" -gt 0 ] || die "nothing has been sent yet: run push first."
  declare -A GOT=()
  local gm gn
  tmp="$(mktemp -d "$RH/.verify.XXXXXX")"; PUSH_STAGE="$tmp"; trap 'rm -rf "${PUSH_STAGE:-}"' EXIT
  t_md5 b > "$tmp/.md5" || die "$R_ERR"
  while read -r gm gn; do [ -n "$gn" ] && GOT["${gn%.age}"]="$gm"; done < "$tmp/.md5"
  for o in "${!U_ROW[@]}"; do
    n=$((n + 1))
    IFS="$TAB" read -r fo b _ _ _ m _ <<<"${U_ROW[$o]}"
    if [ -z "${GOT[$o]:-}" ]; then miss=$((miss + 1)); echo "  MISSING in the copy: $(relevio_safe "$fo/$b")"
    elif [ "${GOT[$o]}" != "$m" ]; then bad=$((bad + 1)); echo "  ALTERED in the copy: $(relevio_safe "$fo/$b")"; fi
  done
  echo "Checked $n bundle(s) by the provider's md5: $miss missing, $bad altered."
  for o in $(printf '%s\n' "${!U_ROW[@]}" | shuf -n "$sample" 2>/dev/null || printf '%s\n' "${!U_ROW[@]}" | head -n "$sample"); do
    IFS="$TAB" read -r fo b _ _ sh _ _ <<<"${U_ROW[$o]}"
    if t_get "b/$o.age" "$tmp/x" && [ "$(sha_of < "$tmp/x")" = "$sh" ]; then echo "  downloaded and checked (sha256): $(relevio_safe "$fo/$b")"
    else bad=$((bad + 1)); echo "  DOWNLOAD FAILED OR DIFFERENT: $(relevio_safe "$fo/$b")${R_ERR:+ ($R_ERR)}"; fi
    rm -f "$tmp/x"
  done
  if t_get catalog.age "$tmp/c"; then
    got="$(sha_of < "$tmp/c")"
    if [ "$got" = "$(config_get catalog_sha)" ]; then echo "  catalog #$(config_get catalog_seq): the one this machine wrote."
    else bad=$((bad + 1)); echo "  CATALOG in the copy is NOT the one this machine wrote last (replaced or rolled back)."; fi
  else bad=$((bad + 1)); echo "  CATALOG missing in the copy (${R_ERR:-?})."; fi
  if [ $((bad + miss)) -eq 0 ]; then echo "The copy is complete and intact."; remote_status_write ok "verified $n"
  else remote_status_write fail "verify: $miss missing, $bad altered or unreadable"; echo "Run push to send again what is missing or altered."; exit 1; fi
}

# --- pull: a new (or reinstalled) machine ------------------------------------------
# Brings keys, catalog and every bundle from the copy into an EMPTY archive
# home, then restore works as on the old machine. Needs a key to open the
# catalog, so it runs only in the user's terminal. Interrupted, it resumes:
# rerun the same command (bundles already here and intact are skipped).
cmd_pull() {
  local kind="${1:-}" target="${2:-}" mid="" use=main machines n tmp o row fo b by mt sh m at i=0 total id kf e
  [ $# -ge 2 ] || die "pull needs: folder <path>, or rclone <remote:path> [--machine <id>] [--recovery]."
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --machine) mid="${2:-}"; shift 2 ;;
      --recovery) use=recovery; shift ;;
      *) die "unknown pull option '$(relevio_safe "$1")'" ;;
    esac
  done
  check_writable; require_tty
  if is_set_up && [ ! -e "$RH/.pull-in-progress" ]; then
    die "this machine already has an archive in $RH. pull is for an empty one (a new or reinstalled computer); to check the copy from here, use verify."
  fi
  find_deps
  mkdir -p "$RH/keys" "$RH/archive"; chmod 700 "$RH" "$RH/keys" "$RH/archive"
  : > "$RH/.pull-in-progress"
  AGE="$(command -v age)"; AGE_KEYGEN="$(command -v age-keygen)"; SHA="$(sha_tool)"
  R_KIND="$kind"; R_TARGET="$target"
  case "$kind" in
    folder) [ -d "$target" ] || die "'$(target_safe "$target")' is not a folder." ;;
    rclone) RCLONE="$(command -v rclone)" || die "rclone is not installed: sudo apt install rclone (Linux) or see https://rclone.org/install/" ;;
    *) die "pull needs: folder <path>, or rclone <remote:path>." ;;
  esac
  tmp="$(mktemp -d "$RH/.pull.XXXXXX")"; PUSH_STAGE="$tmp"; trap 'rm -rf "${PUSH_STAGE:-}"' EXIT
  t_list_machines > "$tmp/machines" || die "$R_ERR"
  machines="$(grep -E '^[0-9a-f]{12}$' "$tmp/machines" || true)"
  [ -n "$machines" ] || die "no relevio copy found at $(target_safe "$target") (no machines/ folder in it)."
  if [ -z "$mid" ]; then
    n="$(grep -c . <<<"$machines")"
    [ "$n" -eq 1 ] || die "the copy holds $n machines; pick one with --machine: $(tr '\n' ' ' <<<"$machines")"
    mid="$machines"
  fi
  grep -qx "$mid" <<<"$machines" || die "machine '$(relevio_safe "$mid")' is not in the copy."
  R_BASE="$R_TARGET/machines/$mid"
  echo "Bringing back the archive of machine $mid from $(target_safe "$target")."
  t_get keys/recipients.txt "$RH/keys/recipients.txt" || die "the copy has no keys/recipients.txt: $R_ERR"
  t_get keys/main.age "$RH/keys/main.age" || { [ "$use" = recovery ] || die "the copy has no keys/main.age, so the passphrase cannot open it: rerun with --recovery and your $NAME_REC."; }
  t_get catalog.age "$tmp/catalog.age" || die "the copy has no catalog: $R_ERR"
  { echo "format=$ARCHIVE_FORMAT"; echo "age=$AGE"; echo "age_keygen=$AGE_KEYGEN"; echo "created=$(utc_iso)"; } > "$RH/config"
  [ "$kind" = rclone ] && config_set rclone "$RCLONE"
  # The key opens the catalog; then everything else needs no secret.
  local idn; idn="$(identity_for "$use" "Opening the copy's catalog (the list of what it holds).")"
  "$AGE" -d -i <(printf '%s\n' "$idn") "$tmp/catalog.age" 2>/dev/null | gzip -dc > "$tmp/catalog.tar" \
    || { unset idn; die "that key could not open the copy's catalog. Nothing was brought back."; }
  unset idn
  tar -tf "$tmp/catalog.tar" > "$tmp/entries" || die "the catalog is damaged."
  while IFS= read -r e; do
    case "$e" in ./|./META|./index.tsv|./folders.tsv|./forgotten.tsv|./remote.tsv) ;; *) die "the catalog holds an unexpected entry ($(relevio_safe "$e"))." ;; esac
  done < "$tmp/entries"
  mkdir "$tmp/c"; tar -xf "$tmp/catalog.tar" -C "$tmp/c" --no-same-owner
  [ "$(head -1 "$tmp/c/META")" = "relevio-catalog $CATALOG_FORMAT" ] || die "the catalog was made by a newer relevio (or is damaged). Update relevio."
  [ "$(sed -n 's/^machine //p' "$tmp/c/META")" = "$mid" ] || die "the catalog names another machine than its folder: the copy is inconsistent. Nothing was brought back."
  [ ! -f "$tmp/c/index.tsv" ] || [ "$(head -1 "$tmp/c/index.tsv")" = "$INDEX_HEADER" ] || die "the catalog's index is not a format $ARCHIVE_FORMAT index."
  [ -f "$tmp/c/remote.tsv" ] && [ "$(head -1 "$tmp/c/remote.tsv")" = "$REMOTE_HEADER" ] || die "the catalog has no upload records."
  for kf in index.tsv folders.tsv forgotten.tsv remote.tsv; do [ -f "$tmp/c/$kf" ] && cp "$tmp/c/$kf" "$RH/$kf"; done
  config_set machine "$mid"; config_set copy_salt "$(sed -n 's/^copy_salt //p' "$tmp/c/META")"
  config_set remote_kind "$kind"; config_set remote_target "$target"
  config_set catalog_seq "$(sed -n 's/^seq //p' "$tmp/c/META")"; config_set catalog_sha "$(sha_of < "$tmp/catalog.age")"; config_set catalog_md5 "$(md5_of < "$tmp/catalog.age")"
  for kf in main.age recipients.txt; do [ -f "$RH/keys/$kf" ] && config_set "sent_$kf" "$(sha_of < "$RH/keys/$kf")"; done
  write_canary
  echo "Catalog #$(config_get catalog_seq), written $(sed -n 's/^written //p' "$tmp/c/META"). Fetching the bundles..."
  remote_records_load
  total="${#U_ROW[@]}"
  for o in "${!U_ROW[@]}"; do
    i=$((i + 1))
    IFS="$TAB" read -r fo b by mt sh m at <<<"${U_ROW[$o]}"
    id="${b:0:36}"
    index_names_ok "$id" "$fo" "$b" || die "the catalog names an unexpected file ($(relevio_safe "$fo/$b")). Stopped."
    mkdir -p "$RH/archive/$fo"; chmod 700 "$RH/archive/$fo"
    if [ ! -f "$RH/archive/$fo/$b" ] || [ "$(sha_of < "$RH/archive/$fo/$b")" != "$sh" ]; then
      t_get "b/$o.age" "$RH/archive/$fo/$b.part" || die "bundle $i of $total could not be fetched: $R_ERR. Rerun the same pull to resume."
      [ "$(sha_of < "$RH/archive/$fo/$b.part")" = "$sh" ] || { rm -f "$RH/archive/$fo/$b.part"; die "bundle $i of $total in the copy is not what was sent (sha256). Stopped; the rest are untouched."; }
      chmod 600 "$RH/archive/$fo/$b.part"; mv "$RH/archive/$fo/$b.part" "$RH/archive/$fo/$b"
    fi
    # The local file is new, so its mtime is new: record it, or the next
    # push would send everything back.
    read -r by mt <<<"$(file_stat "$RH/archive/$fo/$b")"
    U_ROW["$o"]="$fo$TAB$b$TAB$by$TAB$mt$TAB$sh$TAB$m$TAB$at"
    [ $((i % 50)) -eq 0 ] && echo "  $i of $total"
  done
  remote_records_save
  rm -f "$RH/.pull-in-progress"
  remote_status_write ok "pulled $total"
  log "pull: machine $mid, $total bundle(s), catalog #$(config_get catalog_seq)"
  echo "Done: $total bundle(s) back in $RH, every one checked by sha256."
  echo "Put any conversation back with: bash \"$SELF\" restore <session id>   (list shows them)"
  echo "This machine now continues the same copy. If the old computer still runs relevio, run 'remote off' there."
}
