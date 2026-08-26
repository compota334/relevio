# ZCode (Z.ai) hook investigation: usage IS reachable. Port is GO.

Date: 2026-08-26. Method: probe plugin (`zcode-hook-probe`) capturing all 7
hook events during a real ZCode session on this machine (ZCode desktop,
model GLM-5.3), plus direct inspection of ZCode's local state.

## Facts established (all measured, not read from docs)

1. **Plugin system**: ZCode installs plugins from marketplaces. A local
   folder works as a marketplace if `marketplace.json` sits at its ROOT
   (`.zcode-plugin/marketplace.json` is NOT looked at; `.claude-plugin/`
   also works since ZCode reads Claude marketplaces). Plugin layout and
   `hooks/hooks.json` format are IDENTICAL to Claude Code plugins
   (`{"hooks": {...}}` wrapper, matcher, type command).
2. **Hooks must be enabled globally**: `~/.zcode/cli/config.json` with
   `{"hooks": {"enabled": true}}`. Without it the resolver reports
   `hookCount=0` and nothing fires. A full app restart is required after
   installing a plugin (hooks resolve at startup).
3. **Project-level hooks are ignored** by design (workspace
   `.claude/settings.json` hooks do not load). The ONLY way relevio's hooks
   run in ZCode is as an installed plugin.
4. **Payloads** carry both snake_case and camelCase duplicates of every
   field: `session_id`, `transcript_path`, `hook_event_name`, `cwd`, plus
   `model` ("builtin:zai/GLM-5.3"), `mode`/`permission_mode` ("build"),
   `turnId`, `timestamp`, `traceId`. SessionStart carries `source`
   ("startup").
5. **The transcript is a DECOY for usage purposes**: `transcript_path`
   points to a fresh throwaway temp dir per event
   (`/tmp/zcode-claude-hook-XXXXXX/transcript.jsonl`) holding only recent
   messages in `{"message":{"content":[...],"role":...}}` form. NO usage,
   NO tokens, NO model inside. Often 0 bytes at PreToolUse/PostToolUse
   time. Grep-for-`input_tokens` returns nothing, so relevio's Claude Code
   reader exits silently here.
6. **The real usage lives in SQLite**: `~/.zcode/cli/db/db.sqlite`, table
   `model_usage`, one row per model call, keyed by `session_id` + `turn_id`:
   `input_tokens` (ALREADY includes cache reads, unlike Claude Code's
   additive fields), `output_tokens`, `cache_read_input_tokens`,
   `cache_creation_input_tokens`, `computed_total_tokens`
   (= input + output), `context_exceeded`, `model_id` ("GLM-5.3"),
   `raw_usage_json`. Measured on the probe session: 15,605 total tokens,
   consistent with a trivial session. Current context size ~= latest row's
   `computed_total_tokens` for the session_id. Read-only access while ZCode
   runs works fine (WAL mode). `session_target.token_budget` exists but was
   empty; do not rely on it.
7. **No sqlite3 CLI on this machine**; python3's sqlite3 module works. A
   ZCode reader needs sqlite access (python3 is the pragmatic choice on
   Linux; revisit for macOS/Windows packaging).

## The trap this exposes in v0.20.2's foreign-host fix

v0.20.2 detects a foreign host by ABSENT `transcript_path`. ZCode SENDS a
transcript_path (with a useless file behind it), so that detection does NOT
fire: session-start would promise the ~10% cadence and context-warn would
exit silently on every call. The structural-silence bug, reborn. Detection
must be based on "did a usage read actually succeed", not on payload shape.

## Decision

Port is GO, as a ZCode plugin, with a host-split reader:
- detect ZCode (payload `model` starts with "builtin:" / db path exists),
- read usage from `model_usage` by `session_id` (latest row,
  `computed_total_tokens`),
- window table maps ZCode `model_id` values (note the case difference:
  "GLM-5.3" in db, "builtin:zai/GLM-5.3" in payload, vs "glm-5.3" in
  Claude Code transcripts),
- if the read fails for any reason: the loud once-per-session OFF notice
  (never silence, never a guessed number).

Devin remains blocked on its own probe (`/home/no/VIBE/devin-hook-probe/`),
still pending user execution as of this date.
