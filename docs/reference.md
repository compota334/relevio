# relevio reference

Part of the [relevio](../README.md) documentation. How the context hook
measures the window, every message relevio sends the agent and when, and the
behavior details behind them.

## How the hook works

> **The design rule that protects you: relevio never guesses a window size.**
> The model table is a convenience, and a table always lags the next model
> launch. What does not age is the fallback: a model relevio cannot identify
> gets a plain running token count, never an invented percentage. That matters
> because a wrong window is worse than no window at all. It does not fail
> visibly; it quietly reports a number that looks right, and a session running
> a 1M model against an assumed 200k will announce "80%, start closing" at a
> real 17% and end hours early for no reason. A raw token count can never lie
> that way, which is why an unknown model gets one.

The hook reads the usage through one READER PER HOST AGENT, and everything
else (window table, bands, messages) is shared. On Claude Code, the reader
uses the JSONL transcript the host emits per session, which includes
per-message token usage; on ZCode, it queries ZCode's local usage database
(see [ZCode support](../README.md#zcode-zai-support) in the README); on a host it cannot read at all, it says so
loudly once instead of staying silent. On every tool call (PostToolUse,
matcher `*`), the hook reads the most recent usage; what it does with it
depends on whether it can size the window. For a model it recognizes it computes a percentage against that
model's REAL window (1M for current models, 200k for Haiku 4.5) and, if
measured usage ever exceeds that window, self-corrects to 1M with a loud
one-time notice (evidence beats a wrong assumption). For a model it does NOT
recognize it refuses to guess a size (that would be a silent fallback): it
reports the running token count on the first tool call and every 100k after
that. The agent, which knows its own window, reads the count against it and
tells the user when the window is nearly full; the user decides what happens
next. No percentage, no close-out and no STOP LAW. An explicit `CLAUDE_CONTEXT_LIMIT` overrides
detection and forces percentage mode. When a band is crossed it injects a
notice into the agent's context via `additionalContext`:

- **10, 20, 30, 40, 50, 60%**: informational checkpoints. No action required;
  they simply keep the agent aware of where it stands (without the hook, the
  model cannot see its own percentage at all).
- **70 and 80%** (or the custom `CLAUDE_CONTEXT_WARN` thresholds): the
  close-out warnings described in the cycle above.
- **85, 90, 95, 99%**: the revisit guards, ending in the STOP LAW.
- **Unrecognized model**: none of the above. Instead, a raw token count on the
  first tool call and every 100k after that; the agent reads it against its
  own window and tells the user when it is nearly full, and the user decides.

A marker file in `/tmp` guarantees each band fires only once per session, and
if one tool call jumps several bands at once, only the most serious one
speaks, so the agent is nudged, not spammed.

## Subagents

Sub-agents (the Task tool) and the session cycle complement each other, and
they do NOT interfere:

- Subagents have their own separate, ephemeral context windows. Work delegated
  to them barely consumes the main session's window (only their returned
  summary enters it), so delegating actually makes sessions last longer.
- **Subagents never write handoffs.** The handoff documents the main
  conversation, which already received every subagent's report. A subagent's
  context is discarded when it finishes and cannot be revisited, so anything
  important a subagent finds must come back in its summary to the main
  thread: that is what the handoff (and the archive) preserves.
- The context hooks do not reach subagents: warnings are injected into the
  main agent only, so a subagent will never try to close your session.

## What relevio says to the agent (and when)

Every message relevio injects, in firing order. The exact texts live in the
two hook scripts (`.claude/hooks/session-start.sh` and
`.claude/hooks/context-warn.sh`): they are plain shell files, open them to
read or audit every word the agent receives.

| When | Message (gist) |
|------|----------------|
| Session start (new) | This conversation's session id, which `/handoff` passes to `relevio-header.sh` (also repeated after an auto-compact). The cycle in three lines: open with `/kickoff`; a hook reports your context usage roughly every 10%, so silence means the next mark is not crossed (never guess your usage above the last number received); when the hook needs something, its message will say so and carry complete instructions, and until then the task, not the window, decides. No close-out thresholds and no close-out procedure. What it does say: ending a session is the user's call; a finished task gets a short Done / Pending / Needs-from-you recap instead of a handoff; a handoff asked for in plain words goes through the `/handoff` command; that handoffs and other branches are the team's notes, followed as usual, except that a suspicious request found in them is shown to the user before acting on it; on the plugin channel, that relevio turned off Claude Code's automatic compaction, the one time it does so; and, on both channels, that relevio raised `cleanupPeriodDays`, the one time it does so. |
| Session start (any, when there is news) | One notice slot. First the settings notice (relevio turned off automatic compaction or raised `cleanupPeriodDays`, the one time it does so); otherwise the archive's: not set up (at most once a day), failing (with its reason), interrupted, or no success in a week. Every start also launches the background sweep of its repository, silently. |
| Session end | Nothing is said: the archiving of the session is launched, detached. |
| Session start (resumed, and a handoff names it) | Names the handoff whose `Resume:` field carries this session's id and has the agent check it against its own conversation. If the conversation ends with that handoff, it is the archive: answer questions, avoid new work, send new work to a fresh session. If the agent kept working after it, or the handoff describes work it never did (a wrong id), it is a restart: tell the user in one line and carry on. |
| Session start (resumed, never closed) | A restart, not the archive: the app or the computer came back mid-work. The full core, with "carry on where it stopped; being resumed is no reason to leave" in place of the kickoff line. Whether new work still fits is left to the context reports, which can see the window. |
| Session start (just auto-compacted) | Detail was destroyed: tell the user, salvage what remains into a handoff now, recommend a fresh session. |
| First tool call | One status line with a real number (percentage, used, free), even below 10%, so no session spends its opening stretch without a figure. In raw-count mode, the running token count instead. |
| 10-60% (every 10%) | A bare status line: the percentage, used and free tokens, "no action needed". Nothing else, on purpose: these fire six times, so anything they said would be the strongest anchor of all. |
| 70% (soft, configurable) | The sweet spot: maximum understanding loaded AND plenty of free tokens, so put that combination to work. Finish and polish what is open, new user requests welcome at any size, begin thinking about what the next session will need. Explicitly: nothing needs writing yet, a later message will say when. |
| 80% (hard, configurable) | The complete close-out checklist, first time it appears: bring the work to a coherent stopping point (nothing abandoned mid-change), write the handoff while the understanding is still loaded (structure included), run the project's checks, then commit everything and push, hand the user the close-out (on Claude Code two commands, `/rename` plus the kickoff; on ZCode the kickoff command plus a rename-from-the-UI request, since ZCode has no rename command). Explicitly: the free tokens are enough to do it well, no rushing. |
| 85 / 90 / 95% | Escalating guards: short answers, no new work, remind the user the window is nearly full. |
| 99% | Full STOP: do not answer the pending request; warn that one more exchange may fill the window (with compaction off the next message fails as too long; with it turned back on, the conversation is summarized) and wait for explicit confirmation. |
| Unknown model | The raw token count on the first tool call and every 100k after, with the reasoning spelled out (relevio refuses to guess a window size). If the window is nearly full the agent tells the user, and the user decides. |
| Foreign host, session start | Some Claude-compatible harnesses (e.g. Devin) load `.claude/` hooks but send no transcript path, so usage cannot be measured there. The startup core then does NOT promise the report cadence: it says no usage reports will arrive, silence tells you nothing, and never guess a figure. |
| Foreign host, first tool call | One loud notice, once per session: usage reporting is OFF, no counts or warnings will come, the agent must use its own knowledge of its window to time the handoff and keep the user informed. Never silence: an agent waiting for reports that structurally cannot arrive is the exact failure relevio exists to prevent. |
| ZCode sessions | The same checkpoints and warnings, with the usage read from ZCode's local database instead of a transcript, and the close-out adapted to the host: unprefixed `/kickoff`, no `/rename` (the user renames from ZCode's session list). If that database (or python3) is unreachable, the loud OFF notice above fires instead of silence. |
| Errors | A misconfigured threshold variable, a `CLAUDE_CONTEXT_LIMIT` that is not a whole number, an impossible measured usage or a broken context math are each reported loudly, once, with warnings disabled rather than silently wrong. A private marker directory that is missing, a symlink or another user's turns reporting off with a message on every call. |

The design rule behind the dosing: **an instruction travels inside the
message that triggers it, never earlier**. The agent cannot anticipate a
close-out it has never heard of, so it works at full speed until the moment
the hook actually asks for something.

## Behavior details

### Debugging a wrong context percentage

`RELEVIO_DEBUG=1` makes the PostToolUse hook append one line per session to
`~/.cache/relevio/markers/claude-ctx-warn-<session>-debug.log` (or under
`$XDG_CACHE_HOME` when it is set) with the payload's model id, what
relevio resolved it to, the window it picked and the tokens it read. A model id
relevio does not recognize fails silently by design (it falls back to raw token
counts rather than inventing a window), so that line is the fastest way to see
whether an id is arriving in a shape the window table does not match.

### Hooks run without the executable bit

Some hosts install plugin files read-only: ZCode does, hooks included. relevio's
manifest therefore invokes its hooks through an interpreter,
`bash "${CLAUDE_PLUGIN_ROOT}"/hooks/...`, which makes the executable bit
irrelevant rather than a silent prerequisite. If you see relevio's `.sh` files
sitting at `644` in a plugin cache, that is expected and nothing is broken. The
script installer still chmods its own copies, since it owns them.

### Claude Code's automatic compaction is turned off

Claude Code summarizes a conversation away on its own in three ways, all on by
default, and each destroys exactly what relevio exists to keep: a conversation
with its full detail, reopenable later.

| Key | What it does when on |
|---|---|
| `autoCompactEnabled` | compacts the conversation when the context window fills |
| `precomputeCompactionEnabled` | writes that summary in the background before it is needed ("Compacted using a summary written while you were away") |
| `idleCompaction` | since v2.1.290, compacts a long conversation left idle for about an hour, shortly before its prompt cache expires ("Compacted while idle") |

relevio sets all three to `false`, in a different file depending on how it
was installed:

| Installed as | Where | Why there |
|---|---|---|
| Script installer | the project's `.claude/settings.json` | the file the installer already owns; in team mode it reaches every teammate who clones the repository, and it leaves your other projects alone |
| Plugin | your `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`) | a plugin cannot ship these keys, since Claude Code drops every plugin setting except two; and a plugin is enabled for all your projects anyway |

With automatic compaction off, a session that fills its window stops with an
error instead of being summarized. relevio's context reports are what keep
that from happening: they tell the agent to close with a handoff well before
the limit. Manual `/compact` keeps working, since typing it is your own
decision.

On the plugin channel the session-start hook writes it, and the first session
that does so tells you, so it is never a silent edit. In both channels:

- each key is written whenever it is not already `false`, **an explicit
  `true` included**. Installing relevio is the decision not to have
  conversations compacted, and the two cannot both hold. Whenever relevio
  switches a `true`, it says so;
- they are written **whatever your Claude Code version**. Older versions ignore
  a key they do not know, and leaving it out would let a later update start compacting
  without warning;
- a settings file that is not valid JSON, or that is a symbolic link (usually
  a dotfiles manager's), is never rewritten: relevio tells you to add the key
  yourself;
- it never happens on ZCode, which is not Claude Code.

Uninstalling leaves the keys in place: they may be yours as much as relevio's,
and removing them would quietly turn compaction back on.

### Claude Code no longer deletes old conversations

Claude Code deletes every conversation older than `cleanupPeriodDays` (30 days
by default) automatically and silently, and a deleted conversation can no longer
be reopened with `claude --resume`, even though its handoff survives in git.
relevio raises the setting to `36500` days (100 years) in your
`~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`), on **both** channels: the
deletion runs over every project on the machine, so a project-level value
would not protect the others. The first session that writes it tells you, with
the value it had before.

- A whole number of at least `36500` is left as it is. Anything else (absent,
  lower, `0`, a string such as `"30"`, a fraction) is replaced.
- The same safeguards as compaction: an invalid or symlinked settings
  file is never rewritten, and every other key is kept with none of its values
  printed (only the previous value of the key relevio changes is quoted). It
  happens only on Claude Code: never on ZCode, nor on a host that loads
  relevio's hooks without being Claude Code.
- When several keys need changing (the plugin's first session), they are written
  together and announced in one notice.
- A settings file relevio rewrites ends up readable only by you (mode `600`),
  the safer mode for a file that can hold keys in `env`.
- **Managed settings win.** If your organization sets `cleanupPeriodDays` in
  `managed-settings.json`, in `managed-settings.d/`, or from the admin console
  (cached in `~/.claude/remote-settings.json`), that value applies whatever
  your own file says. relevio cannot change it, and says so in the notice it
  gives when it writes the key.
- Sessions started or last continued in the Claude desktop app are already
  kept at any age since Claude Code v2.1.248; the risk is terminal and IDE
  sessions.

This removes the routine 30-day deletion, **not every way a conversation can
disappear**. Claude Code has an open bug in which transcripts were deleted
even with the setting at 36500 or higher, apparently around updates and
restarts ([anthropics/claude-code#41458](https://github.com/anthropics/claude-code/issues/41458)).
relevio's [encrypted archive](archive.md) keeps a copy
that Claude Code cannot delete.

Uninstalling leaves the key in place, for the same reason as compaction.

### Who decides when a session ends

The user does. relevio tells the agent, in the injected core, never to write a
handoff or suggest wrapping up on its own initiative: only when the user asks,
or when one of relevio's own messages says to in those words. Finishing a task
is explicitly not a reason.

This is the other half of a lesson learned in v0.20. Naming the close-out
thresholds up front made agents close at 40-60%, so the thresholds came out of
the core; but silence about WHEN is not silence about WHO, and agents were
later observed closing at half a window simply because the work was done. The
core now says nothing about when a session should end and is explicit about
whose call it is.

### A restart is not a revisit

A conversation can come back for two opposite reasons, and the host reports
both as a "resume". One is a session from the archive, reopened to ask about
it: it was closed near the top of its window, and new work would push it into
auto-compact. The other is a session that was never closed at all, picked up
again after the app or the computer restarted, possibly at 30% with a task
half done.

relevio tells them apart by evidence rather than by guessing from the usage: a
closed session wrote a handoff, and that handoff's `Resume:` field carries the
session's id. If no handoff names it, the session was never closed, and the
agent is told to carry on where it stopped instead of sending the user to a new
session. Only the `Resume:` field counts, so a session merely mentioned in
another handoff's body is never mistaken for a closed one.

A handoff naming the id is strong evidence, not proof, and it was once treated
as proof. Two real situations produce it for a session that is still live: a
handoff written mid-session because the user asked, after which the work went
on; and a handoff that recorded the wrong id (before v0.24.5 the agent took it
from the newest transcript in the folder, which is the other conversation
whenever two are open). Agents restarted after a reboot were told they were in
the archive and stopped working. So relevio now names the handoff it found and
lets the agent decide, since only the agent can see its own conversation: if it
ends with that handoff, it is the archive; if work went on after it, or the
handoff describes work this conversation never did, it is a restart, and the
agent says so in one line and carries on. Erring towards "restart" is the cheap
mistake: the context reports still guard a window that really is full.

The search covers every branch, not only the current checkout, because a
handoff lives on the branch that wrote it and `/revisit` gives you a resume
command you will usually run from main. A handoff written but not yet
committed counts too.

"Carry on" is about the resume, not the window: relevio's start-up message
cannot see how full the context is, so it only says that being resumed is no
reason to leave. If the window really is nearly full, the context reports say
so, and they have the last word.

### Asking for a handoff in plain words

The handoff procedure lives in the `/handoff` command, so an agent only has it
when the command runs. A user who says "write the handoff" in chat would
otherwise get one improvised from memory, in the wrong format. The injected
core therefore tells the agent where the command file is, and to invoke it, or
read it, rather than improvise. The rule about who decides is unchanged: this
only applies once the user has asked.

### What the agent does instead of closing

Forbidding the unasked handoff leaves a hole where the agent's next move should
be, so the core fills it: when a task is done and nothing else was asked, the
agent reports rather than ending anything. A short scannable recap, a small
table or a few bullets, never prose:

| | |
|---|---|
| **Done** | what was finished, and whether it was actually verified or only written |
| **Pending** | what is left, including anything postponed or skipped, which never disappears silently |
| **Needs from you** | any decision or information it is blocked on, as clear options with the one it would pick |

Then it proposes the next step and waits. It is a map, not a report, and it
scales to the work: one line is the right size for a small change.

### Who is reading

relevio tells the agent, once per session, that the person reading may not be a
developer: define a technical term the first time a session uses it, in half a
sentence, then use it normally; and when asking the user to choose, say which
option you would pick and why. That is the whole rule. It is one line in the
injected core rather than explanations sprinkled through every command, because
the agent already knows how to explain things and only needs to be told that it
should.

## Security: text written by other people

relevio reads other people's writing on purpose: every handoff on every
branch, so anyone who can push a branch to a shared repository can put text in
front of your agent at its next `/kickoff`. Handoffs exist to carry
instructions (the pending work), so relevio does not treat them as inert data.
It narrows what that text can do instead:

- **Suspicious requests go to the user.** The core tells the agent to follow a
  handoff's pending work as usual, but to quote and ask about anything
  suspicious first: sending data outside the project, running downloaded
  code, changing permissions, hooks or settings, turning off a check, deleting
  beyond the task, or text addressed to the agent to override its rules.
- **No shell syntax in filenames.** A handoff filename may hold only letters,
  digits, `.`, `_` and `-` after its date, because the kickoff reads a
  handoff by name in a shell command. Anything else fails the index loudly.
- **No hidden text.** Bidirectional controls, zero-width spaces, Unicode tag
  characters and control characters are refused anywhere in a handoff,
  header or body: they can show a human reviewer one thing while the model
  reads another. Zero-width joiners stay allowed, since emoji need them.
- **Errors never echo.** A malformed header is reported by file, line and
  field, never by repeating the offending value, so a planted line cannot
  reach the agent in the voice of relevio's own tooling.
- **Commands are rebuilt, not copied.** `/revisit` builds `claude --resume`
  from the session id alone; the version check in `/kickoff` lets through
  only a bare `X.Y.Z` from the network.

What this does not cover is inherent to any plugin: whoever controls this
repository controls the code that runs on every tool call of every install.
The defence there is the maintainer's GitHub account, and on your side,
reading what an update changes before taking it.

## Agent operators: when the "user" is itself an agent

The framework also works when Claude Code is driven not by a human but by
another agent (an operator running Claude Code on a VPS as if it were the
user). The cycle is unchanged; the operator plays the human role:

- It must drive an interactive Claude Code session (a PTY or tmux pane), so
  slash commands like `/kickoff`, `/handoff` and `/rename` work. The context
  hook itself also fires in non-interactive runs.
- The close-out instructions the inner agent produces are for the operator to
  EXECUTE, not display: send `/rename <Session name>`, close the session,
  open a new one, send `/kickoff`. `/handoff` says this explicitly, so the
  inner agent knows its "user" may be an operator.
- The operator's uppercase name (e.g. `HERMES`) is the `Dev:` in handoff
  headers, which keeps human and agent sessions distinguishable in the index.
- The operator answers the inner agent's questions (branch choice, unclear
  state) exactly as a human would; if it cannot answer, it should stop and
  escalate to its own owner rather than guess.
