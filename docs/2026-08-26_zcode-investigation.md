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

## Open question (v0.22): does ZCode expose CLAUDE_PLUGIN_ROOT to the agent?

Measured, and already handled:
- The hook process on ZCode DOES receive `CLAUDE_PLUGIN_ROOT` when relevio is
  installed as a plugin, but `HOST` is `zcode` there and never becomes
  `plugin` (the `script -> plugin` promotion only fires when HOST is still
  `script`). v0.22 shipped one close-out message that branched on `HOST` and
  therefore handed ZCode users the script install's `.claude/scripts/` path,
  which a plugin install never creates. Fixed by resolving the path inside the
  hook from `CLAUDE_PLUGIN_ROOT` itself, which is the question that actually
  matters (which CHANNEL installed relevio, not which product is running).

NOT measured, and unresolved:
- The `/kickoff` and `/handoff` command bodies are static text, so they cannot
  resolve anything in advance: they tell the agent to run
  `S="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/.claude}/scripts"`.
  That works only if the shell the agent opens INHERITS `CLAUDE_PLUGIN_ROOT`.
  On Claude Code it does. On ZCode it is unverified.
- If it turns out ZCode does not pass it through, the fallback resolves to
  `.claude/scripts`, which a plugin install does not have, and the agent gets
  "No such file or directory" from every script call. The failure is loud and
  the command text says what it means, so nothing breaks silently, but the
  scripts would be unusable from the commands on that host.

How to settle it, in one ZCode session:

    echo "[${CLAUDE_PLUGIN_ROOT:-UNSET}]"
    ls "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/scripts"

A path plus a listing means the commands work as written. `UNSET` means the
command bodies need a ZCode-specific way to find the plugin directory (or the
scripts have to reach the project some other way on that host), and the hook's
close-out is the only path that keeps working.

## Settled (v0.22.1): two ZCode facts, both measured on a real plugin install

A ZCode agent ran the probe in a live session with relevio v0.22.0 installed
as a plugin (user scope, `~/.zcode/cli/plugins/cache/relevio/relevio/0.22.0/`).
Two findings, and both broke v0.22.0:

1. **`CLAUDE_PLUGIN_ROOT` does NOT reach the agent's shell.** It is injected
   for plugin HOOKS (ZCode's own hook guide says so, and it is how the hooks
   are invoked), but `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"` from the agent's
   Bash tool prints `UNSET`. So a slash command's static body can never
   resolve it: v0.22.0's commands fell through to `.claude/scripts`, which a
   plugin install does not create, and their own prose then told the agent to
   conclude "this relevio predates v0.22" and recommend `install.sh --update`
   on a perfectly good install.

2. **ZCode installs plugin files without the executable bit.** Every file in
   the cache is `-rw-rw-r--`, hooks included. ZCode's `diagnosing-hooks` skill
   lists this as a known pitfall and prescribes the fix: invoke through an
   interpreter so the bit is irrelevant. relevio's `hooks/hooks.json` was
   executing its hooks directly.

### What v0.22.1 does about it

- Both hooks locate the scripts from their OWN path
  (`dirname "${BASH_SOURCE[0]}"/../scripts`). hooks/ and scripts/ are siblings
  in both install channels, so this needs no environment variable and works on
  every host. `session-start.sh` then announces the resolved path to the agent
  on a "WHERE THE SCRIPTS ARE" line, which is the only channel proven to work
  here, and the commands quote that path instead of deriving one.
- `hooks/hooks.json` invokes both hooks as `bash "${CLAUDE_PLUGIN_ROOT}"/...`.
  The script channel keeps its direct invocation: `install.sh` chmods those
  itself, and changing the command string would make `register_hook` append a
  second entry to an existing `.claude/settings.json` instead of replacing it.
- Every readiness test is `-r`, never `-x`: on ZCode executability proves
  nothing.
- The commands carry a fallback that reads `installPath` from
  `~/.zcode/cli/plugins/installed_plugins.json`, for the case where the
  session-start line is not in the agent's context.

Still unverified: whether v0.21.5 and earlier ever ran their hooks at all on a
ZCode PLUGIN install, given the stripped executable bit. The 0.21.5 cache was
replaced by the upgrade, so it can no longer be inspected.

## Missing on the ZCode side: no CLI to update a plugin (feature request)

Measured while fixing v0.22.1: `zcode` on the PATH is the Electron launcher,
with no subcommands. There is no `zcode plugin update`, no `zcode plugin
install`, nothing an agent or a script could call. The only supported way to
move a plugin to a new version is the client UI, Settings -> Plugins.

Two consequences relevio has to live with:

- An agent cannot upgrade relevio for the user on ZCode. It can confirm the
  new version is published and hand over the exact click path, and that is
  where its job ends. Editing `~/.zcode/cli/plugins/` by hand is not a
  workaround: `installed_plugins.json`, the cache tree and the transaction ids
  are the host's own state, and a half-applied edit breaks plugin loading for
  every project, not only the one being fixed. The kickoff command says this
  in those words.
- Even a correct update does not reach the running session: hooks and commands
  are registered when a session starts. Any upgrade path has to end with
  "open a new session", which is why the instruction says so explicitly rather
  than leaving the user wondering why nothing changed.

This is a gap in ZCode, not in relevio. Worth filing with Z.ai as a feature
request: a `zcode plugin` subcommand (list / install / update / remove) would
let agents and CI manage plugins the way `claude plugin` does.

## ZCode sometimes labels a fresh session `source=resume`

Observed 2026-09-12: a session that started clean received the "REOPENED
conversation" banner, which `session-start.sh` emits when the hook payload
says `source=resume`. The hook is doing exactly what it is told; the
classification comes from the host.

The visible effect is that a brand new session is told to keep answers short
and not start new work, which is the opposite of what it should do. There is
nothing relevio can check against it: the payload is the only signal about how
a session began, and second-guessing it would break real resumes, which is the
case the banner exists for.

If you see the banner on a session you just opened, say so and carry on
normally. It is a host misclassification, not a state relevio is tracking.

## ZCode composes its payload model id from three columns

Measured 2026-09-13. `model_usage` in ZCode's database keeps `provider_id`
(`builtin:zai`), `model_id` (`GLM-5.3`) and `variant` (`max`) as separate
columns, and the hook payload arrives with them concatenated:
`builtin:zai/GLM-5.3-max`.

relevio's window table matches model ids exactly, on purpose: GLM variants
differ in window size, so a loose match could give a session the wrong
percentage. But the exact match was being run against the composed string,
which is in no catalogue, so every ZCode session dropped to RAW-COUNT mode and
never saw a percentage at all.

The fix undoes the host's composition before matching, rather than adding the
composed string to the table:

- the provider prefix (`builtin:`, then any `provider/`) is not part of the
  model's identity;
- `-low` / `-high` / `-max` are REASONING EFFORT levels, not models. Z.ai's own
  documentation (docs.z.ai/guides/llm/glm-5.3, read 2026-09-13) lists them as
  the three effort levels of a single model with one 1M-token window.

So `builtin:zai/GLM-5.3-max` resolves to `glm-5.3` and gets 1M, while a real
variant suffix such as `-air` is left alone and an unrecognized id still falls
to raw counts. Nothing is guessed: the suffix is read back off a string the
host itself assembled.

Worth knowing for the next time: `RELEVIO_DEBUG=1` dumps the payload model, the
resolved id and the chosen window to /tmp once per session, which answers this
class of question in one run instead of a database autopsy.
