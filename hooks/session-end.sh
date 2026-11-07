#!/bin/bash
# relevio v0.25.0
# relevio: archive this session as it ends.
#
# Claude Code runs SessionEnd hooks when a session closes (exit, /clear, a new
# login), and does not wait for them: hooks share about 1.5 s. So this hook
# only LAUNCHES the archiving, detached, and returns at once; the archive
# script waits for the transcript to stop changing (it may lag the last turn),
# takes the lock, and encrypts the session to the public keys. Nothing here
# holds a secret, and nothing is printed: SessionEnd output is not shown to
# anyone, and a background run reports through the archive's status file,
# which the next session start reads.
#
# A no-op on ZCode (its sessions are not JSONL transcripts) and when relevio's
# scripts are not beside its hooks; the archive script decides the rest.
# Requires jq.
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
PAYLOAD_MODEL=$(echo "$INPUT" | jq -r '.model // empty' 2>/dev/null)

# ZCode, fingerprinted as in session-start.sh: by its builtin:* model or by its
# throwaway transcript path.
case "$TRANSCRIPT" in */zcode-claude-hook-*) exit 0 ;; esac
[ "${PAYLOAD_MODEL#builtin:}" != "$PAYLOAD_MODEL" ] && exit 0
[ -n "$TRANSCRIPT" ] || exit 0

# The scripts sit beside the hooks in both install channels.
RELEVIO_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)"
[ -n "$RELEVIO_SCRIPTS" ] && [ -r "$RELEVIO_SCRIPTS/relevio-archive.sh" ] || exit 0

# Detached by the script itself, so Claude Code is never held up. The script
# answers everything else: off, not set up, an id that is not a session id,
# a transcript that is not where it expects one.
bash "$RELEVIO_SCRIPTS/relevio-archive.sh" sync --session "$SESSION_ID" --transcript "$TRANSCRIPT" \
  --wait-stable --detach </dev/null >/dev/null 2>&1
exit 0
