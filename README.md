# relevio

Session memory for AI coding agents. An agent forgets everything when its
context window fills; relevio makes every session end with a written handoff
and every new session start from it, so nothing one conversation learned is
lost to the next. For Claude Code and ZCode.

## Quick start

1. Install it as a Claude Code plugin (or with the
   [script installer](#option-2-script-installer-per-repo-team-mode), to
   commit it into one repo for a team):

   ```
   /plugin marketplace add compota334/relevio
   /plugin install relevio@relevio
   ```

2. Open a new session and type `/relevio:kickoff` (`/kickoff` on ZCode or
   with the script installer). The agent reads the last handoff, shows the
   board of open work, and asks which branch to continue on.
3. Work as usual. When you are done, ask for a handoff. The agent writes
   `docs/handoff/YYYY-MM-DD_<title>.md`, commits it, and gives you the two
   commands to rename this conversation and open the next one.

## What you will see

The agent cannot see how full its own context window is. relevio tells it, on
its first tool call and then about every 10%:

```
CONTEXT: 8% of your context window used: 83247 of 1000000 tokens, 916753 still free.
This is your first report; the next one arrives when you cross 10%, and silence
until then means you have not. Status update, no action needed.
```

`/kickoff` opens with the team board, generated from every handoff on every
branch:

```
| Branch            | Dev(s) | Last handoff                         | Ahead of main |
|-------------------|--------|--------------------------------------|---------------|
| `session-archive` | NICO   | 2026-11-26_relevio-v0250-prueba-...  | 39            |
```

## What it does

- **Tells the agent how much room it has**, in tokens, so it neither starts a
  big change it cannot finish nor stops early "to be safe".
- **Ends every session with a handoff**: what was done (with commit hashes),
  what is pending and why. Handoffs accumulate in `docs/handoff/`, and
  `docs/handoff/INDEX.md` catalogs them: one row per session, linking the
  handoff, the conversation name and the commit range.
- **Keeps a team's work apart**: one lane per branch, a board of who has open
  work where, and a trace of who touched a file
  ([docs/teams.md](docs/teams.md)).
- **Never summarizes a conversation behind your back**: it turns off Claude
  Code's automatic compaction (`autoCompactEnabled`,
  `precomputeCompactionEnabled` and `idleCompaction`, all `false`), so any
  old conversation can be reopened weeks later with its full detail and
  asked "why did we choose X here?".
- **Never lets one be deleted**: `cleanupPeriodDays` goes to 36500 (100
  years, instead of Claude Code's default 30 days), and an optional
  [encrypted archive](#archiving-every-conversation) keeps a copy of every
  conversation, with a copy off the machine and Bitcoin timestamps.

> **About `docs/handoff/` in this repository:** relevio is developed with
> relevio. Those notes (in Spanish) are this project's own session history,
> not something the installer ships.

## The two problems it solves

1. **Auto-compact loses the detail.** Left on, Claude Code summarizes a
   conversation when its window fills (or while you are away), and the
   fine-grained state of your work (what was tried, what failed, what is
   half-done) is gone forever. relevio turns it off and closes each session
   with a handoff instead, at 80% of the window, with room to do it well.
2. **The agent is blind to its own context usage.** You can see the percentage
   in your statusline; the model cannot. It will happily start a large
   refactor at 85% of the window and hit the wall in the middle of it. The
   installed hook un-blinds it.

## What gets installed (into your project)

| File | Purpose |
|------|---------|
| `.claude/hooks/context-warn.sh` | PostToolUse hook: reads token usage from the transcript and keeps the agent aware of its window. A first report on the first tool call, informational checkpoints every 10% (10-60%), close-out warnings at 70% and 80%, revisit guards at 85/90/95/99% (each once per session). |
| `.claude/settings.json` | Hook registration (merged into your existing settings, never clobbered). |
| `.claude/commands/kickoff.md` | The `/kickoff` slash command: opens a session (regenerates the index, shows the lane board, reads the latest handoff **of your branch**, traces who else has touched the surfaces you are about to work on, checks git state, summarizes where things stand). |
| `.claude/commands/handoff.md` | The `/handoff` slash command: closes a session (writes the dated handoff with its metadata header, regenerates the index, hands over the literal close-out steps). |
| `.claude/commands/revisit.md` | The `/revisit` slash command: finds an old session in the library and returns the `claude --resume <session-id>` command to reopen its conversation. |
| `.claude/hooks/session-end.sh` | SessionEnd hook: launches the archiving of the session that just ended, detached, and prints nothing. A no-op until the archive is set up. |
| `.claude/hooks/session-start.sh` | SessionStart hook: tells the agent the session cycle at the start of every session (open with `/kickoff`; a hook will speak when it needs something). It names no close-out threshold and teaches no close-out procedure: those travel inside the warning that triggers them, so the agent cannot anticipate them. What it does say is that ending a session is the user's call. A conversation reopened from the archive gets the revisit rules instead, one resumed after a restart carries on, and one that just auto-compacted is told to salvage what remains into a handoff. |
| `docs/handoff/` | Where handoffs live. They accumulate; the newest one is the next session's starting point. |
| `.claude/scripts/relevio-index.sh` | Regenerates `docs/handoff/INDEX.md` from the header of every handoff on every branch. Fails loud naming the file and field if a header is malformed. |
| `.claude/scripts/relevio-trace.sh` | Answers "which sessions touched this path, and who has unmerged work on it right now". |
| `.claude/scripts/relevio-areas.sh` | Derives a handoff's `Areas:` value from a commit range, for fixing a header by hand. At close-out `relevio-header.sh` computes it with the same code, so the inclusive-range subtlety is handled in one place. |
| `.claude/scripts/relevio-header.sh` | Prints a session's handoff header with the mechanical fields (date, dev, branch, commits, areas, resume) computed, so the agent writes only the title, topics and summary. |
| `.claude/scripts/relevio-migrate.sh` | One-time conversion of pre-v0.22 handoff headers. Run once per repo when upgrading. |
| `.claude/scripts/relevio-archive.sh` | The encrypted conversation archive: setup, backfill, status, list, restore, keys, forget. See [Archiving every conversation](#archiving-every-conversation). |
| `.claude/scripts/relevio-archive-remote.sh` | Part of the archive: the encrypted copy off this machine (remote, push, verify, pull). Sourced, never run on its own. |
| `.claude/scripts/relevio-archive-stamps.sh` | Part of the archive: timestamps (stamp, proof, proof-check). Sourced, never run on its own. |
| `.claude/scripts/relevio-ots-helper.py` | Reads an OpenTimestamps proof without a Bitcoin node; run only with the archive's own Python. |
| `.claude/scripts/relevio-handoffs-lib.sh` | Shared library for the scripts above (sourced, not run). |
| `docs/handoff/INDEX.md` | The library index, **generated** by `relevio-index.sh`: an **Active lanes** board (branches with open work) plus the full **Catalog** (date, conversation name, handoff file, dev, branch, areas, commit range, topics, summary). Never edited by hand, never overwritten by the installer. |

## What the methodology makes your agent do

- **Open with the baton.** `/kickoff` reads the index and the latest handoff
  before touching code, finds it even when the previous session left it on
  another branch, and settles with you which branch to work on.
- **Stay aware of the window.** The agent cannot see its own context
  percentage; the hook tells it, roughly every 10%, stating used AND free
  tokens (a bare percentage reads as scarcer than it is). The checkpoints
  carry numbers and nothing else (no instructions attached), and the agent
  knows the cadence, so silence between reports means "the next mark is not
  crossed yet" instead of room for anxious guessing.
- **Use the sweet spot at 70%.** The soft warning reframes instead of
  braking: maximum understanding loaded plus plenty of free window is the
  most productive stretch of the session. Finish and polish what is open;
  new user requests stay welcome at any size. Writing the handoff is
  explicitly NOT asked for yet.
- **Close before the wall.** At 80% the full close-out checklist arrives (its
  first appearance: nothing before it teaches the close-out): bring the work
  to a coherent stopping point, then a dated handoff with commit hashes,
  lessons and pending work in order, the regenerated index, the commit and
  push (after the handoff, never cutting work mid-change), and literal
  copy-paste instructions for the human.
- **Never work in an archived session.** A conversation closed with a handoff
  is an archive to ask questions of. One that was merely interrupted (the app
  or the computer restarted mid-work) is not: the agent carries on where it
  stopped. Guards fire at 85/90/95%, and at 99% a STOP LAW halts the agent
  until you confirm.

## Install

There are two ways to get relevio: as a **Claude Code plugin** (simplest,
follows you across every project) or with the **script installer** (installs
into one repo, so a team can commit and share it).

### Option 1: Claude Code plugin (simplest)

Inside any Claude Code session, run:

```
/plugin marketplace add compota334/relevio
/plugin install relevio@relevio
```

That's it: the context hook and the commands are active in every project you
open. On Claude Code, plugin commands are namespaced: use `/relevio:kickoff`,
`/relevio:handoff` and `/relevio:revisit`. On ZCode they register WITHOUT the
prefix: plain `/kickoff`, `/handoff` and `/revisit` (the hooks name the right
variant for the host at runtime). `docs/handoff/` is created in each project
the first time you close a session there.

The plugin ships the same SessionStart hook as the installer, arming the agent
with the methodology at the start of EVERY session, kickoff or not. The
injected message adapts to how the session started: a fresh session gets the
operational core, a conversation reopened from the archive gets the revisit
rules automatically (ask, don't work), one resumed after a restart carries on
where it stopped, and a session that just auto-compacted is told to salvage
what remains into a handoff.

The difference from the script installer is only where the methodology lives:
the plugin keeps it inside itself and writes nothing into your project, so
there is no `.claude/` to commit. Use the installer below
when a team should share one methodology and one handoff history, committed
with the code. **Do not run both in the same project**: each injects the
methodology at session start, so the agent would receive it twice, in possibly
different versions. `/kickoff` detects this and tells you to drop one.

### Option 2: script installer (per-repo, team mode)

From your project root (must be a git repository; requires `jq`; Linux and
macOS supported):

```bash
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/compota334/relevio/main/install.sh | bash
```

Or from a local clone:

```bash
git clone https://github.com/compota334/relevio.git
cd /path/to/your/project
bash /path/to/relevio/install.sh
```

The installer is idempotent: re-running it changes nothing unless something is
actually out of date, so a re-run leaves a clean `git diff`. To upgrade an
existing install to a newer relevio, pass `--update`:

```bash
curl -fsSL https://raw.githubusercontent.com/compota334/relevio/main/install.sh | bash -s -- --update
```

`/kickoff` tells you when that is needed: it compares the version stamped in
your install against the published one and reports the result at session start
(including when it could not check, so a failed lookup never passes as
"up to date").

By default the installed files are left for you to commit (team mode:
every dev's agent follows the same rules and the handoff history is shared).
Working solo, or don't want the methodology in the repo? Add `--private`:
it also writes a marked block to `.gitignore` so `.claude/` and
`docs/handoff/` stay local.

### Installing into a project that already has its own instructions

The methodology lives in relevio's own hooks and slash commands under
`.claude/`. Whatever instructions the project already carries are left
exactly as they were.

The one case that needs a human decision is a project that already describes a
session/handoff methodology **written by hand**. The agent would then receive
two cycles and two handoff schemes with no way to tell which one wins, so the
installer stops **before writing anything** and asks you to pick: keep yours
and install only the context hook by hand, delete yours to adopt relevio's, or
pass `--force` if it is a false positive.

> Upgrading from v0.17 or earlier? Back then the methodology was appended into
> `CLAUDE.md` between markers. `install.sh --update` removes that old block and
> cuts nothing else, so everything you wrote around it stays byte for byte.
> From v0.18-0.19? Those versions shipped a `relevio.md` at the project root;
> `--update` removes it too (the hooks now carry the methodology themselves),
> and only when its title line proves it is relevio's file.

### Upgrading an existing install

Run the installer again with `--update`. It refreshes the hooks
and the slash commands to the new version, with every safety check still on.
`--force` is `--update` plus overriding the check above, so reach for it only
when you know that check is a false positive.

**Which version am I on?** The installed files carry a stamp: the first lines of
`.claude/hooks/context-warn.sh` and `.claude/hooks/session-start.sh` both read
`relevio vX.Y.Z`, so `/kickoff` reports it at session start and you can check
offline with `grep -m1 'relevio v' .claude/hooks/context-warn.sh`. No stamp at
all means the install predates version stamping and is well behind.
This matters more than it looks: a stale install runs stale rules, and an
out-of-date model table is how the hook ends up reporting a context percentage
that is simply wrong.

### After installing

- Restart Claude Code in the project (hooks load when a session starts).
- Per dev, once: run `claude update` (old versions do not support the hook)
  and `/statusline` (so the human sees the context % too). The hook maps the
  model to its real context window (1M for current models, 200k for Haiku) and
  warns by percentage; a model it does not recognize gets its raw token count
  every 100k instead of a guessed size. Force percentage mode (or fix a
  mis-detected known model) with
  `"env": {"CLAUDE_CONTEXT_LIMIT": "1000000"}` in your
  `.claude/settings.local.json`. To change the warning thresholds, set
  `"CLAUDE_CONTEXT_WARN": "60,75"` the same way (default `"70,80"`).
- Decide with your team whether the installed files get **committed** (shared
  methodology, recommended for teams: everyone's agent follows the same rules)
  or **gitignored** (personal setup). Same for `docs/handoff/`: commit it as
  shared team history, or ignore it as private notes.

## The cycle

```
new session, first message: /kickoff
  -> agent regenerates INDEX.md from every handoff on every branch and shows
     you the Active lanes board: who has open work, on which branch, on which
     areas
  -> agent reads the latest handoff OF YOUR BRANCH (not the newest in the
     repo, which is probably somebody else's lane); on a brand new branch it
     reads main's and says so
  -> agent asks which files you will touch and traces them: earlier sessions
     that changed them, and unmerged branches sitting on them right now
  -> agent reconciles the branch: it reads the handoff's Branch field, tells
     you where the last session worked and whether that work is on main yet,
     and ASKS whether to continue there or start a new branch (never switches
     on its own)
  -> work (checkpoints every 10% keep the agent aware: used and free tokens,
     no instructions attached; the agent knows the cadence, so silence
     means the next mark is not crossed yet)
  -> hook at 70%: the sweet spot. Max understanding loaded + plenty of free
     window: finish and polish what is open, new requests welcome at any
     size; the handoff is explicitly NOT asked for yet
  -> hook at 80%: the full close-out checklist arrives, its first appearance;
     there are still ~200k free tokens, so it says no rushing, and the
     commit comes AFTER the handoff, never cutting work mid-change
  -> agent writes docs/handoff/YYYY-MM-DD_<short-title>.md (same title as the
     session name). relevio-header.sh prints its metadata header with Date,
     Dev, Branch, Commits, Areas and Resume already computed; the agent fills
     in Session, Topics and Summary. It regenerates INDEX.md, commits, pushes
  -> you rename the session (/rename DD-MM-YY short-title, the exact Session
     name from the header) and open a new one with /kickoff
  -> the old conversation stays intact in your list: reopen it any time
  -> repeat
```

Handoff rules (the agent gets them from the 80% warning and `/handoff`):

- **Funnel structure**: general context, then what was done (with commit
  hashes), files touched, lessons learned (only real ones), pending work in
  order, and any operational state git does not capture (running services,
  which environment is the source of truth, resumable long jobs).
- **Instructions travel with the event, never before** (the anti-anticipation
  rule): an agent that learns the close-out rules, or the threshold numbers,
  at minute zero anchors on them and starts closing before any warning
  arrives, wasting the very window the thresholds protect (observed in real
  sessions: agents "wrapping up" at 60%). So the session-start core names
  no threshold and teaches no close-out (it only says that ending a session is
  the user's call), the checkpoints carry numbers and nothing else, and
  each warning carries its own complete instructions the first time they are
  needed. The one number the core DOES announce is the checkpoint cadence
  (every 10%): it turns silence into information (no new report = the next
  mark is not crossed), which stops the agent from guessing it is near the
  limit when it is not.
- **What the close preserves is the DERIVED understanding**: the next session
  can re-read a file cheaply, but re-deriving "why the obvious fix fails" or
  "these three approaches are already ruled out" costs it half a window.
  That is why the handoff records the reasoning behind anything left open,
  not just its title.
- **Handoffs accumulate**: never delete or overwrite old ones; that is why
  they carry dates. The newest is the starting point, the rest is history.
- **Close-out is literal**: the agent ends every session with copy-paste
  instructions for the human, each command in its own one-click-copyable code
  block (rename the session with `/rename`; open a new one whose first message
  is `/kickoff`). The close-out also names the branch it worked on (see [docs/teams.md](docs/teams.md)).

### Teams

One lane per branch, the board generated from every handoff on every branch,
the header that is computed instead of typed, the trace of who touched a file,
and parallel sessions in worktrees: [docs/teams.md](docs/teams.md).

## How it works inside

How the context hook measures the window, and every message relevio sends the
agent and when: [docs/reference.md](docs/reference.md).

## ZCode (Z.ai) support

relevio also runs inside [ZCode](https://zcode.z.ai), Z.ai's agentic desktop
environment, as a plugin. ZCode's plugin format is Claude Code-compatible
(same manifest fallback, same `hooks/hooks.json` shape, same
`CLAUDE_PLUGIN_ROOT` variable), so the same plugin works on both hosts.

To install: in ZCode go to **Settings -> Plugins**, add
`compota334/relevio` as a marketplace, and install **relevio** from it. Then
enable hooks (they are off by default): put `{"hooks": {"enabled": true}}`
in `~/.zcode/cli/config.json`, and restart ZCode completely (plugins and
hooks resolve at startup).

How it measures usage there: ZCode sends a `transcript_path` in its hook
payloads, but that file is a throwaway per-event copy of recent messages
with NO token data in it, so relevio ignores it and instead queries ZCode's
local usage database (`~/.zcode/cli/db/db.sqlite`, read-only, keyed by the
session id the payload carries). This requires `python3` on the PATH. If the
database or python3 is missing, relevio says so loudly once per session
instead of failing silently; a nonstandard database location can be pointed
at with the `RELEVIO_ZCODE_DB` environment variable. GLM models get their
real windows from the same table as everything else (GLM-5.2/5.3 at 1M,
GLM-5.1/4.6 at 200k); an unrecognized model gets the raw running count, as
always. Note that ZCode ignores project-level hooks by design, so the script
installer does NOT work there: the plugin is the only path.

The GLM Coding Plan also works in the opposite direction: GLM models plugged
into CLAUDE CODE itself (via Z.ai's Anthropic-compatible endpoint) are
recognized by the same window table, with no extra setup.

## Archiving every conversation

Claude Code keeps each conversation as a plain file in `~/.claude/projects/`,
and files can still disappear: its own cleanup, a bug, a deleted folder.
relevio keeps an **encrypted copy of every conversation** of this machine in
`~/.relevio/` (or `$RELEVIO_HOME`), outside every repository, and can put a
lost one back so `claude --resume` opens it again.

- Each session is archived as it ends, and every session start sweeps its
  repository in the background. Both run detached.
- It is encrypted with [age](https://age-encryption.org) to two keys: your
  **passphrase** (everyday) and a **recovery key** (emergency), shown once at
  setup. **If you lose both the passphrase and the recovery key, the archive is
  gone: nobody, relevio included, can open it.**
- Optional: an encrypted copy off this machine (a synced folder, Google Drive,
  or an S3 bucket such as Backblaze B2), and timestamps in Bitcoin that prove a
  conversation existed by a given date.
- Set it up once from your own terminal: `relevio-archive.sh setup` (your AI
  assistant can open the terminal with the command ready; you type only the
  passphrase).

Commands, the copy off this machine, timestamps, and security and limits:
[docs/archive.md](docs/archive.md).

## Revisiting old conversations

Every handoff header records a `Resume:` line with the literal command to
reopen its conversation: `claude --resume <session-id>` (run from the project
root). In the Claude Code UI you can simply click the conversation in the
session list (it has the same name as the handoff's `Session` field). The
`/revisit <topic>` command searches the library and hands you the right
resume command, built from the session id alone: the rest of the `Resume:`
line is free text written by whoever closed that session, so it is never
passed on as a command. An operator agent ([docs/reference.md](docs/reference.md#agent-operators-when-the-user-is-itself-an-agent)) reopens sessions the same way,
by running `claude --resume <session-id>`. If Claude Code no longer has the
conversation, `/revisit` looks for it in the encrypted archive and gives you
the `restore` command to run in your terminal.

A revisited session is for asking, not for working: it reopens near the top
of its context window. The hook fires guard warnings at 85, 90, 95 and 99%;
the 99% one is a full STOP: the agent must not answer, must warn (in the
user's language) that one more exchange may fill the window, and must
wait for explicit confirmation to continue.

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

## Behavior details

Where the context reports come from when a percentage looks wrong, hooks
without the executable bit, the compaction and retention settings relevio
changes, who decides when a session ends, restarts versus revisits, and text
written by other people:
[docs/reference.md#behavior-details](docs/reference.md#behavior-details).

## Tests

```
bash tests/install.sh
```

Asserts the properties the installer promises. Idempotency first: running it
twice in a row must leave the second run with an **empty git diff**. It exists
because the installed section once drifted by one blank line on every single
re-run, so `--update` always reported a change even when nothing had changed,
and a diff that is always dirty is a diff people stop reading. It also checks
that the migrations keep the user's text intact, that nothing the agent
receives before a close-out warning names the thresholds or teaches the
close-out (the anti-anticipation rule), and that every injected message stays
under the size Claude Code will deliver (past that cap the tail is dropped with
no error). Since v0.22 it also builds a small team repository (a bare origin,
one merged branch and one open one, each closing a session) and asserts what
the lane board, the catalog, the trace and the header parser do with it,
including that a malformed header aborts the run naming the file and the field
and leaves the previous index untouched.

## Upgrading from v0.21 or older

Until v0.21 the handoff header was read by people only, so `Branch:` could
carry prose and `Commits:` a `(10 commits)` suffix. Since v0.22 that header is
parsed, and it needs those values bare plus a new `Areas:` field. There is no
tolerant parser for the old shape: there is one migration, run once per repo.

```
bash .claude/scripts/relevio-migrate.sh
```

The installer tells you when a project needs this: after copying its files it
asks the generator whether the handoffs can be indexed, and prints the
generator's own reason if they cannot.

It leaves `Branch` bare and moves the explanation into the body as a
`Branch note:` line, drops the `Commits` suffix, and derives `Areas` from the
commit range with git. It never invents a value: if a range no longer resolves
because the history was rebased or squashed, it reports that file and leaves it
for you. Then rebuild the index and commit both:

```
bash .claude/scripts/relevio-index.sh
```

Handoffs that live on other branches are migrated by running the same pair on
each of those branches, which is also where that fix belongs: the commit that
carries a handoff is the commit that should carry its migration.

## Uninstall

```bash
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/compota334/relevio/main/uninstall.sh | bash
```

Removes the hooks, the commands, the scripts, the settings entries and the private-mode
`.gitignore` block, preserving everything else you had in those files (plus
the legacy `relevio.md` of v0.18-0.19 installs, removed only when its title
line proves it is relevio's). `docs/handoff/` is always KEPT: it is your
project's history. So is `~/.relevio`, the encrypted archive and its keys,
shared by every project: delete it yourself only if you want it gone.

## License

[MIT](LICENSE)
