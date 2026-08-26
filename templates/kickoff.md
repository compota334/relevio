Open this session following the relevio cycle: you are picking up the baton
from the previous session. Each session opens from the previous session's
handoff and will close with its own; a hook watches the context window and
will tell you, explicitly and in the moment, if it needs anything from you.
Act on its messages when they arrive, never in anticipation.

1. Find and read the LATEST handoff, and do NOT assume it lives on your
   current branch. The previous session may have committed it on a feature
   branch you are not on, so it can be missing from your working tree. Steps:
   a. `git fetch --all --prune` (fall back to `git fetch origin`).
   b. Read `docs/handoff/INDEX.md` if present, then find the newest handoff
      across ALL branches (handoff filenames sort chronologically):

          git log --all --diff-filter=A --name-only --format='' -- 'docs/handoff/*.md' \
            | grep -oE 'docs/handoff/[0-9]{4}-[0-9]{2}-[0-9]{2}_[^/]+\.md' | sort -u | tail -1

   c. Read it. If that file is in your working tree, read it directly; if it
      is NOT (it lives on another branch), read it from the ref that has it:

          f=<the path from b>; c=$(git log --all --format='%H' -1 -- "$f"); git show "$c:$f"

   If `docs/handoff/` has no handoffs yet, this is the project's first
   session: say so and skip to step 2.
2. Reconcile the branch BEFORE working (this is where sessions usually get
   lost). The handoff header has a `Branch:` field: the branch the previous
   session worked on. Report your current branch (`git rev-parse --abbrev-ref
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
   the moment, if it needs anything; the session will end with a handoff plus
   a new session. Do not name any warning percentages or thresholds: an agent
   that knows the numbers anchors on them and acts before the hook speaks.
4. Check whether this project's relevio is out of date, and report the result
   in one line. If the session-cycle core was injected TWICE at session start
   (two separate "relevio vX.Y.Z: this project uses the relevio session
   cycle" messages, whatever command names they carry: the plugin and this
   script install arming you in parallel), say so first: two installs means
   the rules arrive twice, in possibly different versions. Tell the user to
   keep one, either by disabling the plugin through the host's plugin manager
   (`/plugin` on Claude Code, Settings -> Plugins on ZCode) or by removing
   this install with `bash <relevio>/uninstall.sh` (which keeps
   `docs/handoff/`). Read the installed version from the stamp,
   and the published one from the repo:

       grep -m1 'relevio v' .claude/hooks/context-warn.sh
       curl -fsSL --max-time 5 https://raw.githubusercontent.com/compota334/relevio/main/VERSION

   Then say which of these is true, and nothing more elaborate:
   - **Same version**: one line confirming it is current. Do not belabour it.
   - **Behind by a little**: mention it as information, not an alarm. Being one
     version behind is not an emergency. Give the upgrade command
     (`bash <relevio>/install.sh --update`, run from this project root) and move
     on. It refreshes only relevio's own files (the hooks and the commands)
     and never touches `CLAUDE.md`, which is yours.
   - **Behind by several versions, or NO stamp at all** (an install predating
     version stamping): say so clearly and recommend upgrading before real work.
     This is the case worth insisting on: a stale model table makes the hook
     report a context percentage that is simply wrong, so the session gets told
     to close at "80%" while it is really at 17%, and nobody can tell from the
     inside that the number is a lie.
   - **Could not check** (no network, curl missing, request timed out): say that
     explicitly, along with the installed version. Never let a failed check pass
     as "up to date": silence would be indistinguishable from a clean result.
5. Then propose starting with the first pending item from the handoff and wait
   for the user's confirmation or their own direction. Do not start coding
   before that confirmation.
