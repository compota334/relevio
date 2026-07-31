# Session methodology (relevio v0.19.0)

Installed by [relevio](https://github.com/compota334/relevio). This is the full
methodology. At every session start `.claude/hooks/session-start.sh` puts its
operational core into the agent's context (the cycle, the pacing thresholds,
the STOP LAW) and points here for the rest, because Claude Code caps how much
a hook may inject and a file this size would arrive cut in a third of the way
through, with no error. So: the agent always knows the cycle, and reads this
file when it needs the detail. `/kickoff` and `/handoff` carry their own
step-by-step rituals.

**This file belongs to relevio and is REPLACED whole by `install.sh --update`.**
Do not write your own instructions here: they would be lost on the next
upgrade. Your instructions belong in `CLAUDE.md`, which relevio never touches.

relevio governs ONE thing: how sessions open, how they are paced against the
context window, and how they close. It deliberately says nothing about how you
code, verify or handle errors: that belongs to each project and each dev, in
`CLAUDE.md`.

The version above is the installed version. If the agent reports it at session
start, a repo that has drifted behind is visible immediately instead of
silently running old rules.

## Sessions and handoffs (context methodology)

A Claude Code session is NEVER stretched until auto-compact: that is where the
detail of the conversation gets lost. The cycle is: new session -> read the
handoff -> work -> close with a handoff -> new session. The full history stays
in `docs/handoff/`, every closed conversation keeps its full context intact
(reopenable later for questions), and every new session starts fresh.

**Commit small and often**, one idea per commit, with a descriptive message.
The commit range recorded in each handoff is meant to narrate the session step
by step (`git log first..last`); a single giant commit narrates nothing.

**When a session starts, the agent must (the `/kickoff` command runs this
ritual):**
1. Read `docs/handoff/INDEX.md` (the session catalog) and the LATEST handoff
   BEFORE touching any code, without assuming it is on your current branch: the
   previous session may have committed it on a feature branch, so it can be
   missing from your working tree. `git fetch --all --prune`, find the newest
   handoff across ALL branches (filenames sort by date), and if it is not in
   your working tree, read it from its ref with `git show <commit>:<path>`.
2. Reconcile the branch BEFORE working. The handoff header's `Branch:` field is
   the branch the previous session worked on. Report your current branch and
   whether that work is already on main (`git merge-base --is-ancestor
   <handoff-commit> origin/main`), then ASK the user which branch to work on,
   explaining the situation ("last session was on `feat-x`, not yet on main;
   you are on `main`"). Never switch branches on your own: switch only on the
   user's confirmation, never over uncommitted changes. If the target branch
   is checked out in another git worktree (`git worktree list`), ask whether
   that worktree's session is still alive: if it is, the user should open the
   session in that worktree; if it closed, free the branch with `git worktree
   remove <path>` (only if clean; never `--force` without the user's explicit
   OK). Offer to prune detached-HEAD worktrees left by closed sessions. If
   the branch is unclear, ASK first.
3. Remind the user of the cycle in two lines: a hook watches the context
   window and will tell the agent, explicitly and in the moment, when to start
   closing and when to write the handoff; the session ends with a handoff plus
   a new session. Do NOT name the exact warning percentages in this reminder
   (or anywhere else): an agent that knows the number anchors on it and starts
   closing before the warning arrives, which wastes the window the thresholds
   exist to protect.

**During the session:** the repo hook (`.claude/hooks/context-warn.sh`) injects
context notices to the agent (the agent CANNOT see its own percentage without
this; the human sees it in the statusline). You will receive two kinds:

- **Informational checkpoints (every 10%)**: no action required and nothing to
  say to the user; use them to PACE the session, never to close it. Know where
  you stand and plan accordingly: with plenty of window left, work normally;
  from around 50-60%, prefer finishing what is open over kicking off the
  largest pending task, and factor the remaining window into any plan you
  propose (a big refactor does not fit in the last 40% of a session). A
  checkpoint is NOT a close signal, and the close-out must never start in
  anticipation of a warning that has not arrived: the warnings carry their own
  instructions and the moment to act on them is when they land, not before.
- **Close-out warnings**, with these rules on arrival:
- **Soft warning: harvest, do not just brake.** Do NOT open
  new work. Among what is ALREADY open, spend the remaining window where the
  context you are holding is worth most. What dies when the session closes is
  not the tokens you read, it is the understanding you DERIVED: readable facts
  (what a file says, where a function lives) the next session re-reads cheaply;
  derived conclusions (why this approach fails, which three you already ruled
  out, the invariant tying two modules together) have to be re-derived, and
  that costs half a session. So close what depends on derived context, and hand
  off what only depends on readable facts: "cheap to do now, expensive to
  explain later" gets done now. Every item you pick must fit COMPLETE in the
  window you have left, this project's verification and a commit included; a
  half-finished refactor leaves the next session worse off than an untouched
  one. Harvesting is picking what is ripe, not planting. Then write the
  handoff, commit and push, aiming to close with 10-15% of the window free so
  the conversation stays complete and reopenable.
- **Hard warning**: write the handoff NOW, before anything else.

**When closing the session (also via `/handoff`):** the close-out is
triggered ONLY by the hook's soft/hard warning or by the user asking for it.
Do NOT write the handoff early just because a phase or component feels
finished: with window still available, keep working. When the warning
arrives, act on your own, without waiting to be asked:
1. Write the handoff to `docs/handoff/YYYY-MM-DD_<short-title>.md`, where
   `<short-title>` is the same kebab-case title the session name carries (no
   author and no "handoff" suffix in the filename; the author goes in the
   metadata header). If that exact filename already exists, the next one
   takes a letter (`_B`, `_C`, ...). Funnel structure (general -> specific ->
   general close):
   context, what was done (with commit hashes), files touched, lessons learned
   (ONLY real problems that took several attempts; never invent one), pending
   work in order, and any operational state git does not capture. For anything
   you left open that depended on context you had DERIVED (approaches already
   ruled out, why the obvious fix does not work, a subtle coupling you found),
   record the REASONING and not just the title: the next session can re-read
   the code, but it cannot re-derive that for free. Do not repeat what is
   already in `CLAUDE.md` or in this file. If the session started from a
   previous handoff, absorb into the new one whatever is still relevant.
   Handoffs ACCUMULATE: never delete or overwrite the old ones (that is why
   they carry dates); the newest is the starting point and the older ones
   remain as history. Start the handoff with the metadata header defined in
   `/handoff` (Session, Date, Dev, Branch, Commits, Resume, Topics, Summary)
   and append the matching row to `docs/handoff/INDEX.md` (append-only: never
   edit or delete old rows).
2. Commit and push the work, after running whatever checks this project
   defines (type-check, linter, build, tests: see `CLAUDE.md`). This is what
   makes the handoff visible to the next session; it must happen before the
   close-out below.
3. If the session runs inside a git worktree (the path from `git rev-parse
   --git-dir` contains `/worktrees/`), release the branch AFTER the push:
   `git switch --detach`. A branch can be checked out in only one worktree,
   so without this it stays locked for future sessions; detaching frees it
   while the worktree stays alive at this session's final commit (the
   conversation remains revisitable). After the close-out, if the user asks
   for more code in this same session, do NOT commit on the detached HEAD
   (those commits belong to no branch and get lost): re-establish a branch
   first (fresh worktree, or ask) and point new work to a new session.
4. Give the user the close-out with LITERAL instructions (assume an
   inexperienced user; this applies to every manual instruction you give). It is
   TWO commands, and you MUST put each one in its own fenced code block so the
   user copies it in one click, never buried inline in a sentence:
   (a) to rename this session, say "Copy and paste this into this same chat and
   press Enter:" followed by a code block containing
   `/rename DD-MM-YY <short title of what was done>` (you build the date and the
   title, identical to the `Session` field of the handoff header; only the human
   can rename); (b) to open the next one, say "Then close this conversation, open
   a NEW one, and paste this as the first message:" followed by a code block
   containing just `/kickoff` (it already finds and reads the latest handoff on
   its own; do NOT ask the user to type anything else). Apart from the blocks,
   state the branch this session worked on and the handoff file, so the next
   session can reconcile the branch even if it opens on a different one.

**Revisiting closed sessions:** old conversations are part of the archive:
reopen one with the `Resume:` command from its handoff header (or `/revisit
<topic>` finds it for you). A revisited session is for ASKING, not working:
it sits near the top of its window. Guard warnings fire at 85, 90, 95 and
99%. **STOP LAW: when the 99% warning arrives, do NOT answer the pending
request. Reply only, in the user's language, that you reached 99% of context,
that continuing will trigger auto-compact and destroy the conversation's
remaining detail, and ask if they are SURE they want to continue. Wait for
their explicit confirmation.** New work belongs in a new session.

**If the "user" is itself an agent** (an operator agent driving Claude Code,
e.g. an autonomous agent on a VPS): the same cycle applies unchanged, with the
operator playing the human role. The operator answers your questions, and the
close-out instructions of step 4 are for IT to execute, not to display: it
sends `/rename <Session name>` into this same session, closes it, opens a new
one, and sends `/kickoff`. NAME in handoffs is the operator's uppercase name
(e.g. HERMES). Everything else (thresholds, handoffs, index) works identically.

**Per-dev setup (once):** update Claude Code (`claude update`; old versions do
not support the hook); enable the statusline with the context percentage
(`/statusline`). The hook maps the session's model to its real context window
(1M for current models, 200k for Haiku) and warns by percentage; a model it
does not recognize gets its raw token count every 100k instead of a guessed
size, and you decide when to hand off. Force percentage warnings (or fix a
mis-detected known model) with
`"env": {"CLAUDE_CONTEXT_LIMIT": "1000000"}` in `.claude/settings.local.json`.
To change the warning thresholds, set
`CLAUDE_CONTEXT_WARN` (e.g. `"60,75"`) the same way; the default pair is
documented in the hook script itself. It is deliberately not written here:
this file reaches the agent, and an agent that knows the exact percentages
anchors on them and starts closing before the warning arrives.
