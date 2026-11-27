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
# What the encrypted catalog carries besides its META (stamps/ is a folder).
CATALOG_FILES=(index.tsv folders.tsv forgotten.tsv remote.tsv stamps.tsv)
# The config keys that describe the copy; `remote set` and `remote off` reset them.
REMOTE_STATE_KEYS=(catalog_seq catalog_hash catalog_stamps sent_main.age sent_recipients.txt sent_recipients.mac readme_sent remote_audit_at)
REMOTE_AUDIT_EVERY=86400
RCLONE_OPTS=(--retries 2 --low-level-retries 3 --contimeout 15s --timeout 60s)

remote_is_set() { [ -n "$(config_get remote_kind)" ]; }
# Sets R_KIND, R_TARGET, R_BASE (this machine's folder in the copy), RCLONE,
# and the checksum the provider keeps for each file (remote_hash_use).
remote_load() {
  R_KIND="$(config_get remote_kind)"; R_TARGET="$(config_get remote_target)"
  local m; m="$(config_get machine)"
  [ -n "$R_KIND" ] || die "no off-machine copy is set. Set one with: $SELF_CMD remote set folder <path> (or rclone <remote:path>)."
  [[ $m =~ ^[0-9a-f]{12}$ ]] || die "$RH/config has no valid machine id; run remote set again."
  remote_hash_use "$(config_get remote_hash)"
  R_BASE="$R_TARGET/machines/$m"
  if [ "$R_KIND" = rclone ]; then
    RCLONE="$(config_get rclone)"
    [ -n "$RCLONE" ] && [ -x "$RCLONE" ] || die "rclone is missing at '$(relevio_safe "$RCLONE")': install it (sudo apt install rclone) and run remote set again."
  fi
}
target_safe() { printf '%s' "$1" | safe_msg; }
rclone_find() { command -v rclone || die "rclone is not installed: sudo apt install rclone (Linux) or see https://rclone.org/install/"; }
# A target goes into the key=value config: a line break would plant keys.
target_ok() { case "$1" in *$'\n'*|*$'\r'*|"") die "the copy's target must be one line, not empty." ;; esac; }

# --- transports ----------------------------------------------------------------------
# Every t_* call either succeeds or returns 1 with R_ERR set to a one-line
# reason the user can act on. Those that return data write it into a file
# given as their first argument: never call them inside $( ), where R_ERR
# would be lost. rclone's exit codes do not tell a lost login from a lost
# network (measured: both exit 1), so the reason comes from its message.
rclone_reason() {  # stdin: rclone's stderr
  local e; e="$(cat)"
  case "$e" in
    *"couldn't fetch token"*|*invalid_grant*|*"token expired"*)
      R_ERR="the login to ${R_TARGET%%:*} expired: run in your terminal: rclone config reconnect ${R_TARGET%%:*}:" ;;
    # Google answers "Quota exceeded for quota metric 'Queries'" with
    # rateLimitExceeded when too many requests reach it (measured
    # 2026-11-25: rclone's shared app hits it often). Not a full disk.
    *rateLimitExceeded*|*userRateLimitExceeded*|*"quota metric"*)
      R_ERR="the provider is limiting requests (rate limit), not out of space: it is retried next time. If it keeps happening, give rclone its own Google client id (README, A copy off this machine)" ;;
    *storageQuotaExceeded*|*"storage quota"*|*"Quota"*|*"quota"*) R_ERR="the cloud storage is full: quota exceeded" ;;
    *"dial tcp"*|*"no such host"*|*"connection refused"*|*"i/o timeout"*|*"network is unreachable"*|*"TLS handshake timeout"*)
      R_ERR="no connection to the cloud: offline, or the provider is down" ;;
    *InvalidAccessKeyId*|*SignatureDoesNotMatch*|*AccessDenied*|*bad_auth_token*|*unauthorized*|*"401"*|*"403 Forbidden"*)
      R_ERR="the cloud refused the key: check the key ID, the secret, and that the key may use this bucket" ;;
    *"directory not found"*|*"object not found"*|*"file not found"*) R_ERR="not found in the copy" ;;
    *) R_ERR="rclone failed: $(printf '%s' "$e" | tail -1 | safe_msg | cut -c1-160)" ;;
  esac
}
rc() {  # run rclone, R_ERR on failure
  local err
  if err="$("$RCLONE" "${RCLONE_OPTS[@]}" "$@" 2>&1 >/dev/null)"; then return 0; fi
  rclone_reason <<<"$err"; return 1
}
# --- connect: the cloud account, in one guided step -------------------------------------
# What the assistant cannot do for the user is typing the cloud key: it is a
# secret. Everything else (which provider, the bucket, the endpoint) comes as
# arguments, asked by the assistant in a form. This writes the rclone remote
# itself (never on a command line, where other processes could see the key),
# proves access, points the copy at it and sends everything.
#
#   remote connect b2 <bucket>                       Backblaze B2
#   remote connect s3 <bucket> <endpoint> [provider] Cloudflare R2, AWS, Wasabi, MinIO...
#   remote connect gdrive [folder]                   Google Drive (browser login)
remote_connect() {
  local kind="${1:-}" bucket="${2:-}" endpoint="${3:-}" provider="${4:-Other}" name conf id key target probe id_label key_label
  require_tty
  RCLONE="$(rclone_find)"
  conf="$("$RCLONE" config file 2>/dev/null | tail -1)"
  [ -n "$conf" ] || die "rclone does not say where its config lives."
  mkdir -p "$(dirname "$conf")"; touch "$conf"; chmod 600 "$conf"
  case "$kind" in
    b2|s3)
      [[ $bucket =~ ^[a-z0-9][a-z0-9.-]{1,62}$ ]] || die "'$(relevio_safe "$bucket")' is not a bucket name (lower case letters, digits, dots and dashes)."
      if [ "$kind" = b2 ]; then
        id_label="the key ID (keyID, a short code)"; key_label="the application key (applicationKey, shown once when you created it)"
      else
        [[ $endpoint =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || die "the endpoint must be an https:// address, for example https://<account id>.r2.cloudflarestorage.com"
        [[ $provider =~ ^[A-Za-z]+$ ]] || die "the provider is one word, for example Cloudflare, AWS, Wasabi or Minio."
        id_label="the access key ID"; key_label="the secret access key"
      fi
      name="relevio-$kind"; target="$name:$bucket/relevio"
      grep -qx "\[$name\]" "$conf" && die "an rclone remote called $name already exists. Remove it first (rclone config delete $name) or use remote set rclone $name:$bucket/relevio."
      ui_title "☁  connecting the copy off this machine ($kind, bucket $bucket)"
      cat <<EOF
Use a key that can reach ONLY this bucket: if it ever leaks, nothing else
of yours is exposed. The key goes into rclone's own config ($conf),
readable only by you; it is never shown, logged or sent to the assistant.
EOF
      ui_step "1 of 2" "$id_label"
      printf 'Key ID: '; id="$(read_line shown)"
      ui_step "2 of 2" "$key_label"
      paste_hint; printf 'Secret (hidden): '; key="$(read_line hidden)"
      [[ $id =~ ^[A-Za-z0-9]{8,128}$ ]] && [[ $key =~ ^[A-Za-z0-9/+=_-]{8,256}$ ]] || { unset key; die "that does not look like a key ID and a key (letters and digits, no spaces). Nothing was saved; run it again."; }
      # The remote is proven in a private scratch config first and joins
      # rclone's real config only once it works: a wrong key is never kept.
      probe="$(mktemp "$RH/.connect.XXXXXX")"; chmod 600 "$probe"; PUSH_STAGE="$probe"
      trap 'rm -f "${PUSH_STAGE:?}" "${PUSH_STAGE:?}.out"; release_lock' EXIT
      { echo "[$name]"
        if [ "$kind" = b2 ]; then echo "type = b2"; echo "account = $id"; echo "key = $key"; echo "hard_delete = false"
        else echo "type = s3"; echo "provider = $provider"; echo "access_key_id = $id"; echo "secret_access_key = $key"; echo "endpoint = $endpoint"; echo "no_check_bucket = true"; fi
      } > "$probe"
      unset key
      ui_step "Checking" "that the key opens the bucket"
      R_TARGET="$target"
      # A listing really asks the provider (a mkdir on S3 can succeed without
      # asking anything).
      RCLONE_CONFIG="$probe" rc_list "$probe.out" lsf --max-depth 1 "$target" \
        || die "$R_ERR. Nothing was kept; check the key and the bucket and run it again."
      { echo; cat "$probe"; } >> "$conf"
      rm -f "${probe:?}" "${probe:?}.out" ;;
    gdrive)
      name="relevio-gdrive"; target="$name:${bucket:-relevio}"
      if ! grep -qx "\[$name\]" "$conf"; then
        ui_title "☁  connecting Google Drive"
        echo "Your browser opens: choose your Google account and allow rclone. It sees only the files it creates."
        "$RCLONE" config create "$name" drive scope=drive.file >/dev/null 2>&1 || die "the Google login did not finish. Nothing was saved; run it again."
      fi
      R_TARGET="$target"
      rc mkdir "$target" || die "$R_ERR" ;;
    *) die "remote connect needs: b2 <bucket>, s3 <bucket> <endpoint> [provider], or gdrive [folder]." ;;
  esac
  ui_ok "The cloud answers with this key."
  remote_set rclone "$target" checked >/dev/null
  lock_or_die PUSH_STAGE
  push_report 0 || ui_warn "Connected and kept; the first send did not finish. It is retried after every session, or now with push."
}

# rc_list <out file> <rclone args>: a listing into the file; a folder that
# does not exist yet is an empty listing, not an error.
rc_list() {
  local o="$1"; shift
  if "$RCLONE" "${RCLONE_OPTS[@]}" "$@" > "$o" 2>"$RH/.rclone.err"; then rm -f "${RH:?}/.rclone.err"; return 0; fi
  rclone_reason < "$RH/.rclone.err"; rm -f "${RH:?}/.rclone.err"
  [ "$R_ERR" = "not found in the copy" ] && { : > "$o"; return 0; }
  return 1
}
folder_ok() {
  [ -d "$R_TARGET" ] || { R_ERR="the folder $(target_safe "$R_TARGET") is gone: is the drive or the sync client mounted"; return 1; }
}
folder_write_err() { R_ERR="could not write into $(target_safe "$R_TARGET"): disk full or no permission"; return 1; }
# t_put <local file> <relative path>. A folder copy goes through <path>.part
# and a rename. With rclone it is ONE call: an object store (Drive, S3, B2)
# only shows an object once its upload completed (measured on Drive: a cut
# upload leaves nothing), and every call costs requests against the
# provider's rate limit (Drive's shared rclone app hit it, 2026-11-25).
t_put() {
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      mkdir -p "$(dirname "$R_BASE/$2")" && cp "$1" "$R_BASE/$2.part" && mv "$R_BASE/$2.part" "$R_BASE/$2" || folder_write_err ;;
    rclone) rc copyto "$1" "$R_BASE/$2" ;;
  esac
}
# t_put_dir <local dir of symlinks> <relative dir>: many files at once.
# rclone runs them in parallel; a cut upload leaves nothing behind on Drive
# (measured), and a partial file elsewhere fails the checksum check that follows.
t_put_dir() {
  local f
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      mkdir -p "$R_BASE/$2" || folder_write_err || return 1
      for f in "$1"/*; do
        [ -e "$f" ] || continue
        cp -L "$f" "$R_BASE/$2/${f##*/}.part" && mv "$R_BASE/$2/${f##*/}.part" "$R_BASE/$2/${f##*/}" || folder_write_err || return 1
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
# t_hash <out file> [<relative path> ...]: "<checksum> <relative path>" for
# the given files, or for every file of this machine's copy (bundles, keys,
# catalog) when none is given, by R_HASH. The provider answers from its own
# records (Drive and S3 keep md5, B2 sha1), so every bundle is checked
# without downloading one; a folder copy is read back.
t_hash() {
  local out="$1" f; shift
  case "$R_KIND" in
    folder)
      folder_ok || return 1
      : > "$out"
      if [ "${1:-}" = --quick ]; then
        # The daily audit of a folder copy: bundles by size (reading 1.5 GB
        # back every day, or downloading a streamed Drive folder, is not an
        # audit); the small files (keys, catalog) by checksum. verify reads all.
        [ -d "$R_BASE" ] || return 0
        while IFS= read -r -d '' f; do
          case "$f" in
            *.part) ;;
            "$R_BASE"/b/*) printf 'size:%s %s\n' "$(file_stat "$f" | cut -d' ' -f1)" "${f#"$R_BASE/"}" >> "$out" ;;
            *) printf '%s %s\n' "$(hash_of < "$f")" "${f#"$R_BASE/"}" >> "$out" ;;
          esac
        done < <(find "$R_BASE" -type f -print0)
      elif [ $# -gt 0 ]; then
        for f in "$@"; do [ -f "$R_BASE/$f" ] && printf '%s %s\n' "$(hash_of < "$R_BASE/$f")" "$f" >> "$out"; done
      elif [ -d "$R_BASE" ]; then
        while IFS= read -r -d '' f; do
          case "$f" in *.part) continue ;; esac
          printf '%s %s\n' "$(hash_of < "$f")" "${f#"$R_BASE/"}" >> "$out"
        done < <(find "$R_BASE" -type f -print0)
      fi
      return 0 ;;
    rclone)
      [ "${1:-}" != --quick ] || shift   # the provider answers from its records: no cheaper form
      if [ $# -gt 0 ]; then
        printf '%s\n' "$@" > "$out.files"
        rc_list "$out.raw" hashsum "$R_HASH" --files-from "$out.files" "$R_BASE" || return 1
      else
        rc_list "$out.raw" hashsum "$R_HASH" "$R_BASE" || return 1
      fi
      awk '$2 !~ /\.part$/ { print $1, $2 }' "$out.raw" > "$out" ;;
  esac
}
# hash_map <listing file>: fills GOT (bundle opaque name -> checksum) and ALL
# (relative path -> checksum), both declared by the caller.
hash_map() {
  local gm gn
  while read -r gm gn; do
    [ -n "$gn" ] || continue
    ALL["$gn"]="$gm"
    case "$gn" in b/*.age) gn="${gn#b/}"; GOT["${gn%.age}"]="$gm" ;; esac
  done < "$1"
}
t_delete() {  # <relative path>; a file already gone is fine
  case "$R_KIND" in
    folder) folder_ok || return 1; rm -f "${R_BASE:?}/${1:?}" ;;
    rclone) rc deletefile "$R_BASE/$1" || [ "$R_ERR" = "not found in the copy" ] ;;
  esac
}
t_list_machines() {  # <out file>
  case "$R_KIND" in
    folder)
      folder_ok || return 1; : > "$1"
      [ ! -d "$R_TARGET/machines" ] || find "$R_TARGET/machines" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' > "$1" ;;
    rclone) rc_list "$1.raw" lsf --dirs-only "$R_TARGET/machines" || return 1; sed 's|/$||' "$1.raw" > "$1" ;;
  esac
}
# remote_hash_use <md5|sha1>: sets R_HASH, R_HASH_LEN (its hex length) and
# HASH, the tool that computes it here, resolved once like SHA.
remote_hash_use() {
  local t=""
  case "$1" in
    md5) R_HASH_LEN=32
      if command -v md5sum >/dev/null 2>&1; then t="$(command -v md5sum)"
      elif command -v md5 >/dev/null 2>&1; then t="$(command -v md5) -q"; fi ;;
    sha1) R_HASH_LEN=40
      if command -v sha1sum >/dev/null 2>&1; then t="$(command -v sha1sum)"
      elif command -v shasum >/dev/null 2>&1; then t="$(command -v shasum) -a 1"; fi ;;
    *) die "$RH/config does not say which checksum the copy is checked by; run remote set again." ;;
  esac
  [ -n "$t" ] || die "no $1 tool found (${1}sum); install coreutils."
  R_HASH="$1"; HASH="$t"
}
# hash_of: stdin's checksum by R_HASH, to compare with what the provider reports.
hash_of() { $HASH | awk '{ print $1 }'; }
# remote_hash_detect <folder|rclone> <target>: picks the checksum the copy is
# proven by (remote_hash_use). A folder is read back here (md5). With rclone,
# the provider's own list decides: md5 when it keeps it (Drive, S3, R2), else
# sha1 (B2 keeps only sha1, measured 2026-11-26). Needs RCLONE for rclone.
remote_hash_detect() {
  [ "$1" = folder ] && { remote_hash_use md5; return 0; }
  rc_list "$RH/.features" backend features "$2" || die "could not ask the provider which checksums it keeps: $R_ERR"
  local hs; hs="$(jq -r '.Hashes[]?' "$RH/.features")"; rm -f "${RH:?}/.features"
  if grep -qx md5 <<<"$hs"; then remote_hash_use md5
  elif grep -qx sha1 <<<"$hs"; then remote_hash_use sha1
  else die "the provider behind $(target_safe "$2") keeps neither an md5 nor a sha1 of its files, so relevio could not prove the copy is intact without downloading all of it. Use another provider (B2, S3, R2, Google Drive) or a synced folder."
  fi
}

# --- what came from the copy is untrusted ---------------------------------------------
# age encrypts but does not prove who wrote a file: anyone holding the public
# keys (they are in the copy) can make a catalog or a bundle the owner's key
# opens. So every record that comes back from the copy is checked field by
# field before any of it is used in a path, a number or the config.
# tsv_valid <index|remote|stamps|forgotten|folders> <file>: 0, or 1 with the
# first bad line number in TSV_BAD.
TSV_BAD=0
tsv_valid() {
  TSV_BAD="$(awk -F'\t' -v k="$1" '
    function hex(v, n) { return v ~ ("^[0-9a-f]{" n "}$") }
    function num(v) { return v ~ /^[0-9]{1,12}$/ }
    function uuid(v) { return v ~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/ }
    function fold(v) { return v ~ /^[^\/]+$/ && v != "." && v != ".." }
    function bund(v, id) { return v ~ ("^" id "(\\.[0-9]{8}T[0-9]{6}Z|\\.orphan-[0-9]{8}T[0-9]{6}Z)?\\.tgz\\.age$") }
    function opt(v, ok) { return v == "-" || ok }
    NR == 1 && k != "forgotten" && k != "folders" { next }
    {
      ok = 0
      if (k == "index") ok = NF == 12 && $1 ~ /^(active|deleted-in-claude|superseded)$/ && uuid($2) && fold($3) && num($6) && hex($7, 64) && num($8) && num($9) && bund($10, $2) && num($11)
      else if (k == "remote") ok = NF == 8 && hex($1, 32) && fold($2) && bund($3, substr($3, 1, 36)) && uuid(substr($3, 1, 36)) && num($4) && num($5) && hex($6, 64) && (hex($7, 32) || hex($7, 40))
      else if (k == "stamps") ok = NF == 10 && $1 ~ /^(pending|stamped|complete|needs-key)$/ && uuid($2) && fold($3) && bund($4, $2) && opt($5, hex($5, 64)) && opt($6, hex($6, 64)) && num($7) && opt($8, num($8)) && opt($9, num($9)) && hex($10, 64)
      else if (k == "forgotten") ok = uuid($1)
      else if (k == "folders") ok = fold($1) && num($3)
      if (!ok) { print NR; exit }
    }' "$2")"
  [ -z "$TSV_BAD" ]
}

# --- upload records ------------------------------------------------------------------
# remote.tsv: opaque folder bundle bytes mtime sha256 checksum uploaded_at, one row
# (checksum by the copy's R_HASH: md5 or sha1)
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
  tsv_valid remote "$REMOTE_TSV" || die "$REMOTE_TSV line $TSV_BAD is malformed; nothing was sent or fetched."
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
remote_status_write() { kv_status_write "$RH/remote.status" "$@"; }
remote_status_field() { kv_status_field "$RH/remote.status" "$1"; }
remote_reset_state() {
  local k
  for k in "${REMOTE_STATE_KEYS[@]}"; do config_unset "$k"; done
  rm -f "${RH:?}/remote.tsv" "${RH:?}/remote.status"
}

# --- push --------------------------------------------------------------------------------
# Every bundle the index names (current, older generations, deleted in
# Claude), then the keys, then the catalog LAST: a catalog in the copy never
# names a bundle that is not there. Called with the lock held; it works in
# PUSH_STAGE, which the caller removes.
#
# push_core <limit> <audit|records>: "audit" first lists what the copy really
# holds (one call; on a folder copy it reads every file back), and sends again
# whatever is missing or altered there. "records" trusts the upload records,
# so an archiving run with nothing new costs no network at all. The runs
# after a session audit once a day; `push` always does.
PUSH_SENT=0; PUSH_PENDING=0; PUSH_STAGE=""
push_core() {
  local limit="${1:-0}" mode="${2:-audit}" fo b f by mt o row sh m n=0 changed=0 rby rmt rhash st_hash
  remote_load; remote_records_load
  # PUSH_STAGE/b holds only the symlinks to send (it is uploaded as is); the
  # listings and the catalog are written beside it.
  PUSH_STAGE="$(mktemp -d "$RH/.push.XXXXXX")"; mkdir "$PUSH_STAGE/b"
  declare -A WANT=() NEW_ROW=() GOT=() ALL=()
  if [ "$mode" = audit ]; then
    t_hash "$PUSH_STAGE/.hash" --quick || return 1
    hash_map "$PUSH_STAGE/.hash"
    config_set remote_audit_at "$(date +%s)"
  fi
  archive_stats
  while IFS="$TAB" read -r _ _ fo _ _ _ _ _ _ b _; do
    f="$RH/archive/$fo/$b"
    [ -n "${A_STAT[$fo/$b]:-}" ] || { log "push: $fo/$b is in the index but missing on disk; not sent"; continue; }
    read -r by mt <<<"${A_STAT[$fo/$b]}"
    o="$(opaque_for "$fo" "$b")"; WANT["$o"]=1
    row="${U_ROW[$o]:-}"
    if [ -n "$row" ]; then
      IFS="$TAB" read -r _ _ rby rmt _ rhash _ <<<"$row"
      [ "$rby" = "$by" ] && [ "$rmt" = "$mt" ] && { [ "$mode" != audit ] || [ "${GOT[$o]:-}" = "$rhash" ] || [ "${GOT[$o]:-}" = "size:$by" ]; } && continue
    fi
    if [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ]; then PUSH_PENDING=$((PUSH_PENDING + 1)); continue; fi
    sh="$(sha_of < "$f")"; m="$(hash_of < "$f")"
    [ ${#sh} -eq 64 ] && [ ${#m} -eq "$R_HASH_LEN" ] && [ ${#o} -eq 32 ] || { R_ERR="could not hash $fo/$b"; return 1; }
    ln -s "$f" "$PUSH_STAGE/b/$o.age"
    NEW_ROW["$o"]="$fo$TAB$b$TAB$by$TAB$mt$TAB$sh$TAB$m$TAB$(utc_iso)"
    n=$((n + 1))
  done < <(tail -n +2 "$INDEX" 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    t_put_dir "$PUSH_STAGE/b" b || return 1
    # Proof the copy holds what was sent: the provider's checksum of each file
    # just sent (only those).
    GOT=(); ALL=()
    local -a sent=()
    for o in "${!NEW_ROW[@]}"; do sent+=("b/$o.age"); done
    t_hash "$PUSH_STAGE/.hash" "${sent[@]}" || return 1
    hash_map "$PUSH_STAGE/.hash"
    for o in "${!NEW_ROW[@]}"; do
      IFS="$TAB" read -r _ _ _ _ _ m _ <<<"${NEW_ROW[$o]}"
      [ "${GOT[$o]:-}" = "$m" ] || { R_ERR="the copy of a bundle does not match what was sent by $R_HASH; it is sent again next time"; return 1; }
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
      t_delete "b/$o.age" || return 1
      unset "U_ROW[$o]"; changed=1
    else
      log "push: $b is in the copy but not in the index; kept (only forget removes from the copy)"
    fi
  done
  [ "$changed" = 1 ] && remote_records_save
  # Keys: sent when they change (a passphrase change rewrites main.age), or
  # when an audit finds them missing or altered in the copy; all of them in
  # one call.
  local -a keys_out=()
  declare -A key_hash=()
  mkdir "$PUSH_STAGE/keys"
  for f in main.age recipients.txt recipients.mac; do
    [ -f "$RH/keys/$f" ] || continue
    m="$(hash_of < "$RH/keys/$f")"
    [ "$(config_get "sent_$f")" = "$m" ] && { [ "$mode" != audit ] || [ "${ALL[keys/$f]:-}" = "$m" ]; } && continue
    ln -s "$RH/keys/$f" "$PUSH_STAGE/keys/$f"; keys_out+=("$f"); key_hash["$f"]="$m"
  done
  if [ "${#keys_out[@]}" -gt 0 ]; then
    t_put_dir "$PUSH_STAGE/keys" keys || return 1
    for f in "${keys_out[@]}"; do config_set "sent_$f" "${key_hash[$f]}"; done
    changed=1
  fi
  # The catalog is rewritten when anything changed (stamps included), and
  # when an audit finds the one in the copy is not the last this machine
  # wrote (replaced, rolled back, deleted).
  st_hash=""; [ -f "$RH/stamps.tsv" ] && st_hash="$(sha_of < "$RH/stamps.tsv")"
  if [ "$changed" = 1 ] || [ -z "$(config_get catalog_seq)" ] || [ "$st_hash" != "$(config_get catalog_stamps)" ] \
     || { [ "$mode" = audit ] && [ "${ALL[catalog.age]:-}" != "$(config_get catalog_hash)" ]; }; then
    catalog_build "$PUSH_STAGE/catalog.age" || return 1
    t_put "$PUSH_STAGE/catalog.age" catalog.age || return 1
    config_set catalog_hash "$(hash_of < "$PUSH_STAGE/catalog.age")"; config_set catalog_stamps "$st_hash"
  fi
  [ "$(config_get readme_sent)" = 1 ] || { readme_write "$PUSH_STAGE/README.txt"; readme_put "$PUSH_STAGE/README.txt" && config_set readme_sent 1; }
  # Everything is in the copy, but a copy whose key list is not sealed with
  # both keys cannot be pulled safely on a new machine: not "ok".
  if [ "$(grep -c '^\(main\|recovery\) ' "$RH/keys/recipients.mac" 2>/dev/null || echo 0)" != 2 ]; then
    R_ERR="sent, but the key list is not sealed with both keys, so a new machine could not trust this copy: run keys check and keys check --recovery once"
    return 1
  fi
  return 0
}
# The catalog: everything a new machine needs to know what the copy holds,
# encrypted to the same keys as the bundles, stamp leaves and proofs
# included (without them a new machine could not hand anyone a proof). Its
# sequence number tells a new machine how recent it is; this machine keeps
# the checksum of the last one it wrote, so a swapped catalog is caught.
catalog_build() {  # <out file>
  local d seq f
  local -a have=()
  seq="$(config_get catalog_seq)"; seq=$(( ${seq:-0} + 1 ))
  d="$(mktemp -d "$RH/.catalog.XXXXXX")"
  { echo "relevio-catalog $CATALOG_FORMAT"; echo "seq $seq"; echo "machine $(config_get machine)"
    echo "copy_salt $(config_get copy_salt)"; echo "written $(utc_iso)"; echo "relevio_version $(relevio_version)"; } > "$d/META"
  for f in "${CATALOG_FILES[@]}" stamps; do [ -e "$RH/$f" ] && have+=("./$f"); done
  # Straight from the archive home: nothing is copied first.
  tar -cf - -C "$d" ./META -C "$RH" "${have[@]}" | gzip -c | "$AGE" -e -R "$RH/keys/recipients.txt" -o "$1" \
    || { rm -rf "${d:?}"; R_ERR="could not encrypt the catalog"; return 1; }
  rm -rf "${d:?}"
  config_set catalog_seq "$seq"
}
readme_write() {
  cat > "$1" <<'TXT'
This folder is an encrypted copy of Claude Code conversations, made by relevio
(https://github.com/compota334/relevio).

Everything under machines/ is encrypted with age, names included: without the
owner's passphrase or recovery key nothing here can be read. To bring it back
on a new computer, install relevio and run, in your own terminal:

    bash .claude/scripts/relevio-archive.sh pull folder <this folder>
    (or: ... pull rclone <remote:path>)

Do not rename or edit the files here.
TXT
}
readme_put() {
  case "$R_KIND" in
    folder) folder_ok && cp "$1" "$R_TARGET/README.txt" ;;
    rclone) rc copyto "$1" "$R_TARGET/README.txt" ;;
  esac
}
# After every archiving run (lock held): send what is new, auditing the copy
# once a day. Never fails the archiving run; the copy's status says it.
push_after_run() {
  remote_is_set || return 0
  run_isolated remote_status_write copy push_auto
}
push_auto() {
  local mode=records last
  last="$(config_get remote_audit_at)"
  [ -n "$last" ] && [ $(( $(date +%s) - last )) -lt "$REMOTE_AUDIT_EVERY" ] || mode=audit
  PUSH_SENT=0; PUSH_PENDING=0; R_ERR=""
  if push_core 0 "$mode"; then remote_status_write ok "sent $PUSH_SENT"
  else remote_status_write fail "$R_ERR"; log "push: $R_ERR"; fi
  [ -z "$PUSH_STAGE" ] || rm -rf "${PUSH_STAGE:?}"
  return 0
}

# --- commands ------------------------------------------------------------------------------
cmd_remote() {
  local sub="${1:-}"; shift || true
  check_writable; is_set_up || die "the archive is not set up in $RH: run setup first."
  tools_load
  case "$sub" in
    set) remote_set "$@" ;;
    connect) remote_connect "$@" ;;
    status) remote_show ;;
    off)
      remote_is_set || { echo "No off-machine copy is set."; return 0; }
      local k; for k in remote_kind remote_target remote_hash rclone; do config_unset "$k"; done
      remote_reset_state
      echo "The off-machine copy is no longer updated. What is already there stays; delete it from the provider yourself if you want it gone." ;;
    *) die "remote needs: connect b2|s3|gdrive ... | set folder <path> | set rclone <remote:path> | status | off" ;;
  esac
}
remote_set() {
  local kind="${1:-}" target="${2:-}" r
  { [ $# -eq 2 ] || { [ $# -eq 3 ] && [ "$1" = rclone ] && [ "$3" = checked ]; }; } || die "remote set needs: folder <path>, or rclone <remote:path>."
  target_ok "$target"
  case "$kind" in
    folder)
      [ -d "$target" ] || die "'$(target_safe "$target")' is not a folder. Create it (or let the sync client create it) first."
      target="$(cd "$target" && pwd -P)"
      case "$target/" in "$(cd "$RH" && pwd -P)/"*) die "the copy cannot live inside the archive itself." ;; esac
      git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 && die "'$(target_safe "$target")' is inside a git repository: the copy must never be one commit away from a push."
      [ -w "$target" ] || die "'$(target_safe "$target")' is not writable." ;;
    rclone)
      r="$(rclone_find)"
      case "$target" in *:*) ;; *) die "an rclone target looks like <remote>:<path>, for example relevio-gdrive:relevio" ;; esac
      RCLONE="$r"; R_TARGET="$target"
      if [ "${3:-}" != checked ]; then
        echo "Checking access to $(target_safe "$target")..."
        rc mkdir "$target" || die "$R_ERR"
      fi
      config_set rclone "$r" ;;
    *) die "remote set needs: folder <path>, or rclone <remote:path>." ;;
  esac
  remote_hash_detect "$kind" "$target"
  config_set remote_hash "$R_HASH"
  [ -n "$(config_get machine)" ] || config_set machine "$(rand_hex 6)"
  [ -n "$(config_get copy_salt)" ] || config_set copy_salt "$(rand_hex 32)"
  config_set remote_kind "$kind"; config_set remote_target "$target"
  remote_reset_state
  echo "Off-machine copy set: $kind $(target_safe "$target")."
  echo "Every bundle, the keys and an encrypted catalog go there; names are opaque."
  echo "Send everything now with: $SELF_CMD push   (later runs send only what is new)"
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
  local n=0 fo b by mt o row rby rmt
  remote_records_load; archive_stats
  while IFS="$TAB" read -r _ _ fo _ _ _ _ _ _ b _; do
    [ -n "${A_STAT[$fo/$b]:-}" ] || continue
    read -r by mt <<<"${A_STAT[$fo/$b]}"
    # A bundle never sent has no record (and no need for its opaque name).
    o="${U_KEY[$fo/$b]:-}"; row="${o:+${U_ROW[$o]:-}}"
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
  tools_load
  remote_is_set || die "no off-machine copy is set: remote set folder <path> | remote set rclone <remote:path>"
  lock_or_die PUSH_STAGE
  push_report "$limit" || exit 2
}
# push_report <limit>: a push the user asked for (lock held), said in words.
push_report() {
  echo "Sending to the copy ($(target_safe "$(config_get remote_target)"))..."
  if push_core "$1" audit; then
    remote_status_write ok "sent $PUSH_SENT"
    ui_ok "Done: $PUSH_SENT bundle(s) sent, catalog #$(config_get catalog_seq). Every name is opaque, everything encrypted."
    [ "$PUSH_PENDING" -eq 0 ] || echo "$PUSH_PENDING more left (--limit); run push again."
  else
    remote_status_write fail "$R_ERR"; log "push: $R_ERR"
    echo "ERROR: $R_ERR. Nothing is lost: what was not sent is sent next time." >&2
    return 1
  fi
}
# verify: path 1, the provider's checksum of EVERY bundle against what was sent
# (nothing downloaded); path 2, a random sample downloaded and checked by
# sha256; plus the catalog this machine wrote last. No secret needed.
cmd_verify() {
  local sample=3 o m sh fo b bad=0 miss=0 n=0 tmp got
  case "${1:-}" in --sample) sample="${2:-}"; [[ $sample =~ ^[0-9]+$ ]] || die "--sample needs a number." ;; "") ;; *) die "verify takes only --sample <n>." ;; esac
  check_home; is_set_up || die "the archive is not set up in $RH."
  tools_load
  remote_load; remote_records_load
  [ "${#U_ROW[@]}" -gt 0 ] || die "nothing has been sent yet: run push first."
  declare -A GOT=() ALL=()
  tmp="$(mktemp -d "$RH/.verify.XXXXXX")"; PUSH_STAGE="$tmp"; trap 'rm -rf "${PUSH_STAGE:?}"' EXIT
  t_hash "$tmp/.hash" || die "$R_ERR"
  hash_map "$tmp/.hash"
  for o in "${!U_ROW[@]}"; do
    n=$((n + 1))
    IFS="$TAB" read -r fo b _ _ _ m _ <<<"${U_ROW[$o]}"
    if [ -z "${GOT[$o]:-}" ]; then miss=$((miss + 1)); echo "  MISSING in the copy: $(relevio_safe "$fo/$b")"
    elif [ "${GOT[$o]}" != "$m" ]; then bad=$((bad + 1)); echo "  ALTERED in the copy: $(relevio_safe "$fo/$b")"; fi
  done
  echo "Checked $n bundle(s) by the provider's own $R_HASH: $miss missing, $bad altered."
  for o in $(printf '%s\n' "${!U_ROW[@]}" | shuf -n "$sample" 2>/dev/null || printf '%s\n' "${!U_ROW[@]}" | head -n "$sample"); do
    IFS="$TAB" read -r fo b _ _ sh _ _ <<<"${U_ROW[$o]}"
    if t_get "b/$o.age" "$tmp/x" && [ "$(sha_of < "$tmp/x")" = "$sh" ]; then echo "  downloaded and checked (sha256): $(relevio_safe "$fo/$b")"
    else bad=$((bad + 1)); echo "  DOWNLOAD FAILED OR DIFFERENT: $(relevio_safe "$fo/$b")${R_ERR:+ ($R_ERR)}"; fi
    rm -f "$tmp/x"
  done
  if t_get catalog.age "$tmp/c"; then
    got="$(hash_of < "$tmp/c")"
    if [ "$got" = "$(config_get catalog_hash)" ]; then echo "  catalog #$(config_get catalog_seq): the one this machine wrote."
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
  local kind="${1:-}" target="${2:-}" mid="" use=main unsealed=no machines n tmp o row fo b by mt sh m at i=0 total id kf e
  [ $# -ge 2 ] || die "pull needs: folder <path>, or rclone <remote:path> [--machine <id>] [--recovery] [--accept-unsealed]."
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --machine) mid="${2:-}"; shift 2 ;;
      --recovery) use=recovery; shift ;;
      --accept-unsealed) unsealed=yes; shift ;;
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
  target_ok "$target"
  R_KIND="$kind"; R_TARGET="$target"
  case "$kind" in
    folder) [ -d "$target" ] || die "'$(target_safe "$target")' is not a folder." ;;
    rclone) RCLONE="$(rclone_find)" ;;
    *) die "pull needs: folder <path>, or rclone <remote:path>." ;;
  esac
  remote_hash_detect "$kind" "$target"
  # The lock keeps a session starting or ending meanwhile from archiving into
  # a home whose index this pull is about to replace.
  PUSH_STAGE=""; lock_or_die PUSH_STAGE
  tmp="$(mktemp -d "$RH/.pull.XXXXXX")"; PUSH_STAGE="$tmp"
  t_list_machines "$tmp/machines" || die "$R_ERR"
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
  local idn rc=0; idn="$(identity_for "$use" "Opening the copy's catalog (the list of what it holds).")"
  # The key list must be the owner's: sealed with the key just typed (anyone
  # who can write to the copy could have added a key of their own).
  [ -n "$(printf '%s\n' "$idn" | "$AGE_KEYGEN" -y 2>/dev/null | grep -xFf - "$RH/keys/recipients.txt")" ] \
    || { unset idn; die "the copy's key list does not contain the key you typed: it is not this archive's. Nothing was brought back."; }
  if t_get keys/recipients.mac "$RH/keys/recipients.mac"; then
    seal_check "$use" "$idn" || rc=$?
    [ "$rc" -eq 0 ] || { unset idn; die "the copy's key list does NOT match its seal: someone may have added a key to it. Nothing was brought back; do not use this copy until you know why."; }
  else
    # No seal: a copy from before the seal existed, or one someone tampered
    # with. When the old machine is gone this is the only way back, so it is
    # the owner's decision, and it needs BOTH secrets: the list must be
    # exactly the two public keys derived from them (with one secret only, an
    # attacker could have swapped the other key for theirs).
    local keys other other_use mine theirs
    keys="$(grep -c '^age1' "$RH/keys/recipients.txt" || true)"
    echo "The copy's key list has no seal: either it was made before relevio sealed key lists, or someone removed the seal. It holds $keys key(s)." >&2
    [ "$unsealed" = yes ] || { unset idn; die "to bring it back anyway you need BOTH keys (passphrase and recovery key): rerun with --accept-unsealed. Otherwise do not use this copy."; }
    if [ "$use" = main ]; then other_use=recovery; other="$(read_recovery_identity)"
    else other_use=main; other="$(read_main_identity "The copy has no seal: its key list is checked against BOTH your keys.")"; fi
    mine="$( { printf '%s\n' "$idn" | "$AGE_KEYGEN" -y; printf '%s\n' "$other" | "$AGE_KEYGEN" -y; } 2>/dev/null | sort)"
    theirs="$(grep '^age1' "$RH/keys/recipients.txt" | sort)"
    [ "$(grep -c . <<<"$mine")" = 2 ] && [ "$mine" = "$theirs" ] \
      || { unset idn other; die "the copy's key list is NOT exactly your two keys: someone may have changed it. Nothing was brought back."; }
    seal_write "$use" "$idn"; seal_write "$other_use" "$other"; unset other
  fi
  "$AGE" -d -i <(printf '%s\n' "$idn") "$tmp/catalog.age" 2>/dev/null | gzip -dc > "$tmp/catalog.tar" \
    || { unset idn; die "that key could not open the copy's catalog. Nothing was brought back."; }
  unset idn
  tar -tf "$tmp/catalog.tar" > "$tmp/entries" || die "the catalog is damaged."
  while IFS= read -r e; do
    case "$e" in
      ./|./META|./index.tsv|./folders.tsv|./forgotten.tsv|./remote.tsv|./stamps.tsv|./stamps/) ;;
      ./stamps/*) [[ $e =~ ^\./stamps/[0-9a-f]{64}\.leaf(\.ots)?$ ]] || die "the catalog holds an unexpected entry ($(relevio_safe "$e"))." ;;
      *) die "the catalog holds an unexpected entry ($(relevio_safe "$e"))." ;;
    esac
  done < "$tmp/entries"
  mkdir "$tmp/c"; tar -xf "$tmp/catalog.tar" -C "$tmp/c" --no-same-owner
  # Only plain files and folders: a link would make the copies below read a
  # file of this machine (an SSH key, a cloud token) into the archive, and the
  # next push would send it out.
  [ -z "$(find "$tmp/c" ! -type f ! -type d -print -quit)" ] || die "the catalog holds a link or a special file: it was not made by relevio. Nothing was brought back."
  local seq salt
  [ "$(head -1 "$tmp/c/META")" = "relevio-catalog $CATALOG_FORMAT" ] || die "the catalog was made by a newer relevio (or is damaged). Update relevio."
  [ "$(grep -c '^machine ' "$tmp/c/META")" = 1 ] && [ "$(sed -n 's/^machine //p' "$tmp/c/META")" = "$mid" ] || die "the catalog names another machine than its folder: the copy is inconsistent. Nothing was brought back."
  seq="$(sed -n 's/^seq //p' "$tmp/c/META")"; salt="$(sed -n 's/^copy_salt //p' "$tmp/c/META")"
  [[ $seq =~ ^[0-9]{1,9}$ ]] && [[ $salt =~ ^[0-9a-f]{64}$ ]] || die "the catalog's header is malformed: it was not made by relevio. Nothing was brought back."
  [ ! -f "$tmp/c/index.tsv" ] || [ "$(head -1 "$tmp/c/index.tsv")" = "$INDEX_HEADER" ] || die "the catalog's index is not a format $ARCHIVE_FORMAT index."
  [ -f "$tmp/c/remote.tsv" ] && [ "$(head -1 "$tmp/c/remote.tsv")" = "$REMOTE_HEADER" ] || die "the catalog has no upload records."
  [ ! -f "$tmp/c/stamps.tsv" ] || [ "$(head -1 "$tmp/c/stamps.tsv")" = "$STAMPS_HEADER" ] || die "the catalog's stamp records are not relevio's."
  for kf in index:index.tsv remote:remote.tsv stamps:stamps.tsv forgotten:forgotten.tsv folders:folders.tsv; do
    [ ! -f "$tmp/c/${kf#*:}" ] || tsv_valid "${kf%%:*}" "$tmp/c/${kf#*:}" \
      || die "the catalog's ${kf#*:} line $TSV_BAD is malformed: it was not made by relevio. Nothing was brought back."
  done
  for kf in "${CATALOG_FILES[@]}"; do [ -f "$tmp/c/$kf" ] && cp -P "$tmp/c/$kf" "$RH/$kf"; done
  [ -d "$tmp/c/stamps" ] && { mkdir -p "$RH/stamps"; chmod 700 "$RH/stamps"; cp -P "$tmp/c/stamps/"* "$RH/stamps/" 2>/dev/null || true; }
  [ -f "$RH/stamps.tsv" ] && config_set catalog_stamps "$(sha_of < "$RH/stamps.tsv")"
  config_set machine "$mid"; config_set copy_salt "$salt"
  config_set remote_kind "$kind"; config_set remote_target "$target"; config_set remote_hash "$R_HASH"
  config_set catalog_seq "$seq"; config_set catalog_hash "$(hash_of < "$tmp/catalog.age")"
  for kf in main.age recipients.txt recipients.mac; do [ -f "$RH/keys/$kf" ] && config_set "sent_$kf" "$(hash_of < "$RH/keys/$kf")"; done
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
  echo "Put any conversation back with: $SELF_CMD restore <session id>   (list shows them)"
  echo "This machine now continues the same copy. If the old computer still runs relevio, run 'remote off' there."
}
