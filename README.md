# relevio

Pass the baton between Claude Code sessions instead of running them into the
ground. One command installs a complete working methodology into any project:
ordered, named, never-compacted sessions with written handoffs, plus the
engineering rules that keep an agent honest (fail loud, phased work, mandatory
verification).

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
| `.claude/commands/kickoff.md` | The `/kickoff` slash command: opens a session (reads the index and the latest handoff, checks git state, summarizes where things stand). |
| `.claude/commands/handoff.md` | The `/handoff` slash command: closes a session (writes the dated handoff with its metadata header, appends the index row, hands over the literal close-out steps). |
| `.claude/commands/revisit.md` | The `/revisit` slash command: finds an old session in the library and returns the `claude --resume <session-id>` command to reopen its conversation. |
| `CLAUDE.md` | The full working methodology (see below), appended between markers if you already have a CLAUDE.md. |
| `docs/handoff/` | Where handoffs live. They accumulate; the newest one is the next session's starting point. |
| `docs/handoff/INDEX.md` | The library index: one append-only row per session (date, conversation name, handoff file, commit range, topics, summary). Never overwritten, not even with `--force`. |

## What the CLAUDE.md section makes your agent do

The installed section is not only about sessions; it sets the working rules
that make agent output trustworthy:

- **Fail loud, never fake success.** The agent must prefer a visible failure
  over any silent fallback: no placeholder data, no cached defaults, no
  "compatibility" code paths, no swallowed exceptions. If something cannot
  work, it raises a clear error and says why. This matters because silent
  fallbacks are how agents hide bugs: everything looks green until production.
- **Mandatory verification.** Nothing is reported as "done" until the
  project's own checks (type-check, lint, build, tests) ran clean on what was
  touched. If the project has no checks, the agent must say so instead of
  claiming success.
- **Phased work.** No multi-file refactors in one pass: explicit phases of 5
  files or fewer, verified one by one. Dead-code cleanup goes in its own
  commit before any structural refactor.
- **Senior-level standards.** Wrong architecture or duplicated state gets a
  structural fix, not a patch on top.
- **Grep-discipline for renames.** Direct calls, type references, string
  literals, dynamic imports, tests: searched separately, because one grep
  never catches everything.
- **Re-read before editing** in long conversations, instead of trusting stale
  context memory.
- **The session cycle** (open with the handoff, close before the window fills,
  leave literal copy-paste instructions for the human).

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
open. Plugin commands are namespaced: use `/relevio:kickoff`,
`/relevio:handoff` and `/relevio:revisit`. `docs/handoff/` is
created in each project the first time you close a session there.

The plugin also ships a SessionStart hook that arms the agent with the
methodology at the start of EVERY session, kickoff or not (plugins cannot
auto-load a CLAUDE.md, so this hook plays that role). The injected message
adapts to how the session started: a fresh session gets the cycle summary, a
REOPENED conversation gets the revisit rules automatically (ask, don't work),
and a session that just auto-compacted is told to salvage what remains into a
handoff.

What the plugin does NOT carry: the CLAUDE.md methodology section (plugins
cannot auto-load CLAUDE.md content). The session cycle works fully; if you
also want the engineering rules (fail loud, phased work, mandatory
verification) written into a repo for every dev's agent, use the script
installer below (both can coexist: the hook warns only once per session).

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

The installer is idempotent: re-run it any time to update. It never overwrites
a file you have edited unless you pass `--force`:

```bash
curl -fsSL https://raw.githubusercontent.com/compota334/relevio/main/install.sh | bash -s -- --force
```

By default the installed files are left for you to commit (team mode:
every dev's agent follows the same rules and the handoff history is shared).
Working solo, or don't want the methodology in the repo? Add `--private`:
it also writes a marked block to `.gitignore` so `CLAUDE.md`, `.claude/` and
`docs/handoff/` stay local.

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
  -> agent finds the latest handoff ACROSS ALL BRANCHES (not just the current
     one) and reads it, plus INDEX.md
  -> agent reconciles the branch: it reads the handoff's Branch field, tells
     you where the last session worked and whether that work is on main yet,
     and ASKS whether to continue there or start a new branch (never switches
     on its own)
  -> work
  -> hook warns at 70%: finish what is open, no new large tasks
  -> hook warns at 80%: write the handoff NOW
  -> agent writes docs/handoff/YYYY-MM-DD_<short-title>.md (same title as the
     session name; metadata header: Session, Date, Dev, Branch, Commits,
     Resume, Topics, Summary), appends the INDEX.md row, commits, pushes
  -> you rename the session (/rename DD-MM-YY short-title, the exact Session
     name from the header) and open a new one with /kickoff
  -> the old conversation stays intact in your list: reopen it any time
  -> repeat
```

Handoff rules (the agent gets them from CLAUDE.md and `/handoff`):

- **Funnel structure**: general context, then what was done (with commit
  hashes), files touched, lessons learned (only real ones), pending work in
  order, and any operational state git does not capture (running services,
  which environment is the source of truth, resumable long jobs).
- **Handoffs accumulate**: never delete or overwrite old ones; that is why
  they carry dates. The newest is the starting point, the rest is history.
- **Close-out is literal**: the agent ends every session with copy-paste
  instructions for the human (rename the session, open a new one, first
  message: "read the handoff X and let's continue"). The close-out also names
  the branch it worked on (see below).

### Handoffs live on the branch you worked on

A handoff is committed like any other file, so it lands on whatever branch the
session was working on. If that was a feature branch and your next session
opens on `main` (or in a different git worktree), the newest handoff is simply
**not in that branch's working tree** — a naive `ls docs/handoff/` would miss
it and the new session would read a stale one and lose track of the branch.
`/kickoff` handles this: it looks for the latest handoff across **all** branches
(`git log --all` by filename date), reads it from its ref with `git show` when
it is not checked out, then reconciles: it reports the branch the last session
worked on (the handoff's `Branch:` field), whether that work already reached
main, and **asks you** whether to continue there or branch off. It never
switches branches on its own, and if the branch is checked out in another
worktree it tells you to open the session there. Two things make this reliable:
the handoff always records its `Branch:`, and the close-out always commits and
pushes before handing over.

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

Claude Code emits a JSONL transcript per session that includes per-message
token usage. On every tool call (PostToolUse, matcher `*`), the hook reads the
most recent usage entry; what it does with it depends on whether it can size
the window. For a model it recognizes it computes a percentage against that
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

## Revisiting old conversations

Every handoff header records a `Resume:` line with the literal command to
reopen its conversation: `claude --resume <session-id>` (run from the project
root). In the Claude Code UI you can simply click the conversation in the
session list (it has the same name as the handoff's `Session` field). The
`/revisit <topic>` command searches the library and hands you the right
resume command. An operator agent (see below) reopens sessions the same way,
by running `claude --resume <session-id>`.

A revisited session is for asking, not for working: it reopens near the top
of its context window. The hook fires guard warnings at 85, 90, 95 and 99%,
and the installed CLAUDE.md contains a STOP LAW: at 99% the agent must not
answer; it must warn (in the user's language) that one more exchange may
trigger auto-compact and ask for explicit confirmation to continue.

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

## Agent operators: when the "user" is itself an agent

The framework also works when Claude Code is driven not by a human but by
another agent (an operator running Claude Code on a VPS as if it were the
user). The cycle is unchanged; the operator plays the human role:

- It must drive an interactive Claude Code session (a PTY or tmux pane), so
  slash commands like `/kickoff`, `/handoff` and `/rename` work. The context
  hook itself also fires in non-interactive runs.
- The close-out instructions the inner agent produces are for the operator to
  EXECUTE, not display: send `/rename <Session name>`, close the session,
  open a new one, send `/kickoff`. The installed CLAUDE.md says this
  explicitly, so the inner agent knows its "user" may be an operator.
- The operator's uppercase name (e.g. `HERMES`) is the `Dev:` in handoff
  headers, which keeps human and agent sessions distinguishable in the index.
- The operator answers the inner agent's questions (branch choice, unclear
  state) exactly as a human would; if it cannot answer, it should stop and
  escalate to its own owner rather than guess.

## Uninstall

```bash
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/compota334/relevio/main/uninstall.sh | bash
```

Removes the hook, the commands, the settings entry, the CLAUDE.md section
and the private-mode `.gitignore` block, preserving everything else you had
in those files. `docs/handoff/` is always KEPT: it is your project's
history.

## License

[MIT](LICENSE)
