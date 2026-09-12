---
description: Open a session - show the team's lanes, read your branch's handoff, trace who else touched the surfaces you will work on
---

Open this session following the relevio cycle: a session is NEVER
stretched until auto-compact (that is where the conversation's detail gets
lost). Each session opens from the previous session's handoff and will close
with its own; a hook watches the context window and will tell you, explicitly
and in the moment, if it needs anything from you. Act on its messages when
they arrive, never in anticipation. You are picking up the baton from the
previous session.

1. Find YOUR lane and read its latest handoff. Never assume the newest handoff
   in the repo is yours: on a team, other devs and other agents are closing
   sessions on their own branches, and their handoff is not your context.
   a. `git fetch --all --prune` (fall back to `git fetch origin`).
   b. Regenerate and read the library index. It is a GENERATED file: never
      edit it by hand and never resolve a merge conflict on it by hand.

          S="${CLAUDE_PLUGIN_ROOT}/scripts"
          [ -x "$S/relevio-index.sh" ] || S="$(git rev-parse --show-toplevel)/.claude/scripts"
          if [ -x "$S/relevio-index.sh" ]; then bash "$S/relevio-index.sh"; else
            echo "relevio: relevio-index.sh is in neither \${CLAUDE_PLUGIN_ROOT}/scripts nor .claude/scripts. This relevio predates v0.22, or the script install is incomplete: bash <relevio>/install.sh --update" >&2
          fi

      If the script is missing the block prints why: STOP there and tell the
      user, do not hand-edit INDEX.md.
      If it FAILS on a malformed header, it names the file and the field:
      report both. When it says the header predates v0.22, the fix is one
      migration, `bash "$S/relevio-migrate.sh"`, which rewrites the headers in
      this working tree: propose it and wait for the user's OK. Never patch a
      handoff header silently, and never one that belongs to another dev.
   c. Show the user the **Active lanes** table exactly as generated. That is
      the team board: one row per branch with open work, who owns it, which
      areas it touches, how far ahead of main it is.
   d. Your lane is your current branch: `git rev-parse --abbrev-ref HEAD`.
      Read the LAST catalog row whose `Branch` column equals it. If the file
      is in your working tree read it directly; otherwise read it from history:

          f=<the Handoff file cell>; c=$(git log --all --format='%H' -1 -- "docs/handoff/$f"); git show "$c:docs/handoff/$f"

   e. If NO row carries your branch (a brand new branch, or a detached HEAD),
      read the last handoff of the main branch instead, and SAY so in those
      words: "your branch is new, so this is where main stood at its last
      session". Do not silently hand the user someone else's lane as if it
      were theirs.
   f. Ask the user which files or directories this session will touch, then
      trace them BEFORE any code:

          bash "$S/relevio-trace.sh" <path> [<path> ...]

      Rows marked `OPEN WORK` are unmerged branches sitting on that same
      surface right now. Name them to the user as a collision risk, and offer
      to read their latest handoff (same command as d). Rows marked `handoff`
      are earlier sessions on that surface, possibly weeks old and from other
      branches: offer them, and read the ones the user picks. This is the step
      that stops a new branch from silently undoing work it never saw.
   If `docs/handoff/` has no handoffs yet, this is the project's first
   session: say so and skip to step 2.
2. Reconcile the branch BEFORE working (this is where sessions usually get
   lost). The handoff header has a `Branch:` field, a bare branch name: the
   branch that session worked on. Report your current branch (`git rev-parse --abbrev-ref
   HEAD`), whether it is up to date with its remote, and any uncommitted work.
   Then work out where the previous work landed and ASK the user:
   - Is that work already on main? Check with
     `git merge-base --is-ancestor <handoff-commit> origin/main` (or `main`).
     If yes, main already contains it and continuing on main is reasonable; if
     no, the work still lives only on the feature branch.
   - Explain the situation in a line or two and ASK which branch to work on:
     e.g. "the last session worked on `feat-x`, which is NOT yet on main; you
     are on `main`. Continue on `feat-x`, or start a new branch from here?"
   - Do NOT switch branches on your own. Switch only after the user confirms,
     and only safely: never `git checkout` over uncommitted changes. If the
     target branch is checked out in another git worktree (`git worktree
     list`), you CANNOT switch to it here; ask the user whether that
     worktree's session is still ALIVE. If it is, tell them to open the
     session in that worktree's directory instead. If it already closed, free
     the branch from the main repo with `git worktree remove <path>`; but
     only if that worktree is clean; NEVER use `--force` without the user's
     explicit OK (a dirty worktree may hold uncommitted work). If anything
     about the branch is unclear, ASK before touching code.
   - Housekeeping: if `git worktree list` shows worktrees in detached HEAD
     left behind by closed sessions, mention them and offer to prune
     (`git worktree remove <path>`): safe when clean, since their code lives
     in the branches.
3. Give the user a short opening summary: where the project stands according
   to the handoff, the pending work in order, and any operational state the
   handoff recorded (running services, which environment is the source of
   truth, resumable jobs). Close the summary with a one-line reminder of the
   cycle: a hook watches the context window and will speak, explicitly and in
   the moment, if it needs anything; the session will end with a handoff
   (the `/relevio:handoff` command; on ZCode it is plain `/handoff`) plus a
   new session. Do not name any warning percentages or thresholds: an agent
   that knows the numbers anchors on them and acts before the hook speaks.
4. If this project ALSO has a script-installed relevio (its hooks at
   `.claude/hooks/session-start.sh` and `.claude/hooks/context-warn.sh`, or a
   legacy `relevio.md` at the project root), say so FIRST, because two
   installs is a problem before it is a version question: the plugin and the
   script install each inject the methodology at session start, so the agent
   receives it TWICE, and if their versions differ it receives two different
   sets of rules. Tell the user to keep one: either remove the script install
   (`bash <relevio>/uninstall.sh` from the project root, which keeps
   `docs/handoff/`) or disable the plugin (through `/plugin` on Claude Code;
   through Settings -> Plugins on ZCode). Then check whether that script
   install is out of date and report the result in one line. The plugin
   updates through the host's plugin manager, but a script install sitting
   beside it does not, so it is the one that silently rots:

       grep -m1 'relevio v' .claude/hooks/context-warn.sh
       curl -fsSL --max-time 5 https://raw.githubusercontent.com/compota334/relevio/main/VERSION

   Say which of these is true, and no more:
   - **Same version**: one line confirming it is current.
   - **Behind by a little**: information, not an alarm. Give the upgrade command
     (`bash <relevio>/install.sh --update` from this project root) and move on.
   - **Behind by several versions, or NO stamp** (an install predating version
     stamping): say so clearly and recommend upgrading before real work. A stale
     model table makes the hook report a context percentage that is simply
     wrong, so a session gets told to close at "80%" while it is really at 17%,
     and nobody can tell from the inside that the number is a lie.
   - **Could not check** (no network, curl missing, timeout): say so explicitly
     alongside the installed version. Never let a failed check pass as "up to
     date": silence would be indistinguishable from a clean result.
HOST NOTE (ZCode): if this session runs inside ZCode rather than Claude Code,
every relevio command is unprefixed there: `/kickoff`, `/handoff`, `/revisit`
(never `/relevio:...`). ZCode has no `/rename` and no `claude --resume`:
sessions are renamed and reopened from ZCode's own session list.

5. Then propose starting with the first pending item from the handoff and wait
   for the user's confirmation or their own direction. Do not start coding
   before that confirmation.
