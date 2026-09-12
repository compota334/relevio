# relevio

AI coding agents forget everything when their context window fills. relevio
is session memory for them: context-usage awareness in real time, a written
handoff before every close, and a navigable archive of never-compacted,
reopenable sessions. Each session starts where the last one ended. One
command (or one plugin install) puts the whole cycle into any project. For
Claude Code and ZCode.

## The core idea: never lose context again

Without a methodology, working with Claude Code for months looks like this: a
pile of conversations named "Untitled", most of them auto-compacted (their
detail destroyed by summarization), and no record of why anything was done the
way it was.

With relevio, your history becomes a complete, navigable archive:

- **Every conversation gets closed BEFORE auto-compact**, renamed to
  `DD-MM-YY short-title`, and ends with a written handoff document. Your
  session list reads like a project logbook.
- **Every closed conversation keeps 10-15% of its context window free and is
  never compacted.** That remaining room is the point: you can REOPEN any old
  conversation weeks later and ask "why did we choose X here?" or "explain
  that bug you fixed", and the agent answers with the FULL original context
  still intact.
- **Handoffs accumulate in `docs/handoff/`**, dated, never overwritten. Each
  new session starts by reading the latest one, so no knowledge dies when a
  conversation ends.
- **Everything is cataloged.** `docs/handoff/INDEX.md` is the library index:
  one row per session linking its three records: the handoff file, the
  conversation name, and the commit range (`git log first..last` narrates the
  session's work commit by commit, since commit messages are themselves
  summaries of what was done).

The result: TOTAL history. The handoff folder is the written memory, the
index is the catalog, git history is the code trail, and the renamed
conversation list is the archive of complete, still-queryable sessions.
Nothing is ever lost to compaction again.

## The two problems it solves

1. **Auto-compact loses the detail.** When the context window fills up, the
   conversation is summarized and the fine-grained state of your work (what
   was tried, what failed, what is half-done) is gone forever.
2. **The agent is blind to its own context usage.** You can see the percentage
   in your statusline; the model cannot. It will happily start a large
   refactor at 85% of the window and hit the wall in the middle of it. The
   installed hook un-blinds it.

## What gets installed (into your project)

| File | Purpose |
|------|---------|
| `.claude/hooks/context-warn.sh` | PostToolUse hook: reads token usage from the transcript and keeps the agent aware of its window. Informational checkpoints every 10% (10-60%), close-out warnings at 70% and 80%, revisit guards at 85/90/95/99% (each once per session). |
| `.claude/settings.json` | Hook registration (merged into your existing settings, never clobbered). |
| `.claude/commands/kickoff.md` | The `/kickoff` slash command: opens a session (regenerates the index, shows the lane board, reads the latest handoff **of your branch**, traces who else has touched the surfaces you are about to work on, checks git state, summarizes where things stand). |
| `.claude/commands/handoff.md` | The `/handoff` slash command: closes a session (writes the dated handoff with its metadata header, regenerates the index, hands over the literal close-out steps). |
| `.claude/commands/revisit.md` | The `/revisit` slash command: finds an old session in the library and returns the `claude --resume <session-id>` command to reopen its conversation. |
| `.claude/hooks/session-start.sh` | SessionStart hook: tells the agent the session cycle at the start of every session (open with `/kickoff`; a hook will speak when it needs something). It deliberately says NOTHING about closing: every close-out instruction travels inside the warning that triggers it, so the agent cannot anticipate it. A REOPENED conversation gets the revisit rules instead; one that just auto-compacted is told to salvage what remains into a handoff. |
| `docs/handoff/` | Where handoffs live. They accumulate; the newest one is the next session's starting point. |
| `.claude/scripts/relevio-index.sh` | Regenerates `docs/handoff/INDEX.md` from the header of every handoff on every branch. Fails loud naming the file and field if a header is malformed. |
| `.claude/scripts/relevio-trace.sh` | Answers "which sessions touched this path, and who has unmerged work on it right now". |
| `.claude/scripts/relevio-areas.sh` | Derives a handoff's `Areas:` value from its commit range. `/handoff` calls it instead of re-typing the pipeline, so the inclusive-range subtlety is handled in one place. |
| `.claude/scripts/relevio-migrate.sh` | One-time conversion of pre-v0.22 handoff headers. Run once per repo when upgrading. |
| `.claude/scripts/relevio-handoffs-lib.sh` | Shared library for the three scripts above (sourced, not run). |
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
  lessons and pending work in order, an append-only index row, the commit and
  push (after the handoff, never cutting work mid-change), and literal
  copy-paste instructions for the human.
- **Never work in a reopened session.** Old conversations are an archive to ask
  questions of. Guards fire at 85/90/95%, and at 99% a STOP LAW halts the agent
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
operational core, a REOPENED conversation gets the revisit rules automatically
(ask, don't work), and a session that just auto-compacted is told to salvage
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
     session name; metadata header: Session, Date, Dev, Branch, Commits,
     Areas, Resume, Topics, Summary), regenerates INDEX.md, commits, pushes
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
  sessions: agents "wrapping up" at 60%). So the session-start core says
  nothing about closing, the checkpoints carry numbers and nothing else, and
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
  is `/kickoff`). The close-out also names the branch it worked on (see below).

### One lane per branch, and a board for the team

A handoff is committed like any other file, so it lands on whatever branch the
session was working on. With one dev on one branch that is invisible. With a
team it is the whole problem: the newest handoff in the repo belongs to
whoever closed last, which is usually not you, and it is often not even in
your working tree.

So relevio does not have "the latest handoff". It has **one lane per branch**,
plus a board listing the lanes. `docs/handoff/INDEX.md` is generated from the
header of every handoff found across `git log --all`, and has two parts:

- **Active lanes**: one row per branch that still has open work (it exists and
  is not merged into `origin/main`), with the dev who owns it, the areas it
  touches and how far ahead of main it is. This is the team board.
- **Catalog**: every session ever closed, on any branch, oldest first.

`/kickoff` reads the row for **your** branch. On a brand new branch there is no
such row, so it reads main's last handoff and says in plain words that it is
doing so, instead of handing you a stranger's lane as if it were yours.

Because the file is generated, nobody edits it and nobody resolves merge
conflicts on it. When git reports a conflict there, the fix is to rerun the
script and commit the result. The index on a feature branch legitimately lists
sessions from other branches: it is a view of the repository as you last
fetched it, not of your branch.

One trade-off, stated plainly: a handoff survives only while git can reach it.
Delete an unmerged branch and its handoff leaves the index with it. Push and
merge, or lose it. That was already true when the index was hand-written, since
the row lived on that branch too.

### Repositories without a remote

The board measures "merged" and "ahead" against an integration branch, and by
default that is `origin/main`. A repository with no remote has none, so relevio
asks once and the repository remembers:

```bash
git config relevio.main main
```

Every later session uses it. relevio never guesses this: which branch the work
integrates into is a decision, not something to infer from the branch list. It
also refuses `HEAD` and its relatives as an answer, whichever way they were
supplied: they name wherever a checkout is standing right now, so the board
would compare against a different commit each day. This matters here more than
it sounds, because relevio's own close-out leaves worktrees on a detached HEAD. A
one-off override is `--main <ref>` or the `RELEVIO_MAIN` environment variable,
and both win over the recorded value.

### Tracing who touched a surface

The other half of the problem is time, not just branches. When you open a new
branch you are usually about to edit code that other sessions, on other
branches, touched weeks ago. Their reasoning is in their handoffs, and you have
no way to know which ones. `relevio-trace.sh` answers exactly that:

```
$ bash .claude/scripts/relevio-trace.sh src/auth

## src/auth

| Kind      | Branch      | Handoff / tip                | Dev  | Commits touching | Note           |
|-----------|-------------|------------------------------|------|------------------|----------------|
| OPEN WORK | `feat-sso`  | origin/feat-sso              | ANA  | 6                | collision risk |
| handoff   | `main`      | 2026-08-17_auth-rewrite.md   | NICO | 11               | merged         |
```

Two kinds of row. `handoff` rows are past sessions whose commit range touched
that path: read them before you undo their reasoning. `OPEN WORK` rows are
unmerged branches changing the same surface right now, which is the collision
you cannot see from your own branch because their commits are not in main and
therefore not in yours either. `/kickoff` runs this for the areas you say you
will touch, before any code.

### Worktrees and parallel sessions

Running parallel sessions in git worktrees is fully supported, with one rule:
git allows a branch to be checked out in only ONE worktree, so a finished
session must not keep its branch hostage. The close-out handles it: after the
final commit and push, a session running in a worktree runs `git switch
--detach`. That frees the branch instantly for future sessions, while the
worktree directory stays alive, pinned at the session's final commit, so the
closed conversation can still be revisited with its exact code state. If a
closed session is later asked to write more code anyway, it must not commit on
that detached HEAD (such commits belong to no branch): it creates a fresh
worktree or asks first. On the opening side, when `/kickoff` finds the target
branch held by another worktree it asks whether that session is still alive
(open the session there) or finished (free the branch with `git worktree
remove`, never forced), and offers to prune detached leftovers.

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
(see the ZCode section below); on a host it cannot read at all, it says so
loudly once instead of staying silent. On every tool call (PostToolUse,
matcher `*`), the hook reads the most recent usage; what it does with it
depends on whether it can size the window. For a model it recognizes it computes a percentage against that
model's REAL window (1M for current models, 200k for Haiku 4.5) and, if
measured usage ever exceeds that window, self-corrects to 1M with a loud
one-time notice (evidence beats a wrong assumption). For a model it does NOT
recognize it refuses to guess a size (that would be a silent fallback): it
just reports the running token count every 100k and lets the agent -- which
knows its own window -- decide when to hand off, with no percentage, no
close-out and no STOP LAW. An explicit `CLAUDE_CONTEXT_LIMIT` overrides
detection and forces percentage mode. When a band is crossed it injects a
notice into the agent's context via `additionalContext`:

- **10, 20, 30, 40, 50, 60%**: informational checkpoints. No action required;
  they simply keep the agent aware of where it stands (without the hook, the
  model cannot see its own percentage at all).
- **70 and 80%** (or the custom `CLAUDE_CONTEXT_WARN` thresholds): the
  close-out warnings described in the cycle above.
- **85, 90, 95, 99%**: the revisit guards, ending in the STOP LAW.
- **Unrecognized model**: none of the above. Instead, a single raw token count
  every 100k, leaving the handoff call to the agent's own knowledge of its
  window.

A marker file in `/tmp` guarantees each band fires only once per session, and
if one tool call jumps several bands at once, only the most serious one
speaks, so the agent is nudged, not spammed.

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

## What relevio says to the agent (and when)

Every message relevio injects, in firing order. The exact texts live in the
two hook scripts (`.claude/hooks/session-start.sh` and
`.claude/hooks/context-warn.sh`): they are plain shell files, open them to
read or audit every word the agent receives.

| When | Message (gist) |
|------|----------------|
| Session start (new) | The cycle in three lines: open with `/kickoff`; a hook reports your context usage roughly every 10%, so silence means the next mark is not crossed (never guess your usage above the last number received); when the hook needs something, its message will say so and carry complete instructions, and until then the task, not the window, decides. Nothing about closing, handoffs to write, or close-out thresholds. |
| Session start (reopened) | This conversation is an archive: answer questions, avoid new work, send new work to a fresh session. |
| Session start (just auto-compacted) | Detail was destroyed: tell the user, salvage what remains into a handoff now, recommend a fresh session. |
| 10-60% (every 10%) | A bare status line: the percentage, used and free tokens, "no action needed". Nothing else, on purpose: these fire six times, so anything they said would be the strongest anchor of all. |
| 70% (soft, configurable) | The sweet spot: maximum understanding loaded AND plenty of free tokens, so put that combination to work. Finish and polish what is open, new user requests welcome at any size, begin thinking about what the next session will need. Explicitly: nothing needs writing yet, a later message will say when. |
| 80% (hard, configurable) | The complete close-out checklist, first time it appears: bring the work to a coherent stopping point (nothing abandoned mid-change), write the handoff while the understanding is still loaded (structure included), run the project's checks, then commit everything and push, hand the user the close-out (on Claude Code two commands, `/rename` plus the kickoff; on ZCode the kickoff command plus a rename-from-the-UI request, since ZCode has no rename command). Explicitly: the free tokens are enough to do it well, no rushing. |
| 85 / 90 / 95% | Escalating guards: short answers, no new work, remind the user the window is nearly full. |
| 99% | Full STOP: do not answer the pending request; warn that one more exchange may trigger auto-compact and wait for explicit confirmation. |
| Unknown model | The raw token count every 100k, with the reasoning spelled out (relevio refuses to guess a window size) and the close-out decision left to the agent. |
| Foreign host, session start | Some Claude-compatible harnesses (e.g. Devin) load `.claude/` hooks but send no transcript path, so usage cannot be measured there. The startup core then does NOT promise the report cadence: it says no usage reports will arrive, silence tells you nothing, and never guess a figure. |
| Foreign host, first tool call | One loud notice, once per session: usage reporting is OFF, no counts or warnings will come, the agent must use its own knowledge of its window to time the handoff and keep the user informed. Never silence: an agent waiting for reports that structurally cannot arrive is the exact failure relevio exists to prevent. |
| ZCode sessions | The same checkpoints and warnings, with the usage read from ZCode's local database instead of a transcript, and the close-out adapted to the host: unprefixed `/kickoff`, no `/rename` (the user renames from ZCode's session list). If that database (or python3) is unreachable, the loud OFF notice above fires instead of silence. |
| Errors | A misconfigured threshold variable, an impossible measured usage or a broken context math are each reported loudly, once, with warnings disabled rather than silently wrong. |

The design rule behind the dosing: **an instruction travels inside the
message that triggers it, never earlier**. The agent cannot anticipate a
close-out it has never heard of, so it works at full speed until the moment
the hook actually asks for something.

## Revisiting old conversations

Every handoff header records a `Resume:` line with the literal command to
reopen its conversation: `claude --resume <session-id>` (run from the project
root). In the Claude Code UI you can simply click the conversation in the
session list (it has the same name as the handoff's `Session` field). The
`/revisit <topic>` command searches the library and hands you the right
resume command. An operator agent (see below) reopens sessions the same way,
by running `claude --resume <session-id>`.

A revisited session is for asking, not for working: it reopens near the top
of its context window. The hook fires guard warnings at 85, 90, 95 and 99%;
the 99% one is a full STOP: the agent must not answer, must warn (in the
user's language) that one more exchange may trigger auto-compact, and must
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

### Hooks run without the executable bit

Some hosts install plugin files read-only: ZCode does, hooks included. relevio's
manifest therefore invokes its hooks through an interpreter,
`bash "${CLAUDE_PLUGIN_ROOT}"/hooks/...`, which makes the executable bit
irrelevant rather than a silent prerequisite. If you see relevio's `.sh` files
sitting at `644` in a plugin cache, that is expected and nothing is broken. The
script installer still chmods its own copies, since it owns them.

### Who is reading

relevio tells the agent, once per session, that the person reading may not be a
developer: define a technical term the first time a session uses it, in half a
sentence, then use it normally; and when asking the user to choose, say which
option you would pick and why. That is the whole rule. It is one line in the
injected core rather than explanations sprinkled through every command, because
the agent already knows how to explain things and only needs to be told that it
should.

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
project's history.

## License

[MIT](LICENSE)
