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
# A no-op on ZCode (its sessions are not JSONL transcripts), when relevio's
# scripts are not beside its hooks, when archiving is off or not set up, and
# for an id that is not a Claude Code session id. Requires jq.
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

RH="${RELEVIO_HOME:-$HOME/.relevio}"
[ ! -e "$RH/off" ] && [ -s "$RH/keys/recipients.txt" ] || exit 0

LC_ALL=C
case "$SESSION_ID" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) exit 0 ;;
esac

# Detached, all three descriptors closed, so Claude Code is never held up.
# Measured (Claude Code 2.1.316): a child started this way finishes after the
# claude process has exited. The archive script itself reports a transcript
# that is not where it expects one.
l=""; command -v setsid >/dev/null 2>&1 && l=setsid
$l nohup bash "$RELEVIO_SCRIPTS/relevio-archive.sh" sync --session "$SESSION_ID" \
  --transcript "$TRANSCRIPT" --wait-stable </dev/null >/dev/null 2>&1 &
exit 0
