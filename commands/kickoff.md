---
description: Open a session — read the latest handoff, check git state, summarize where things stand
---

Open this session following the relevio cycle: a session is NEVER
stretched until auto-compact (that is where the conversation's detail gets
lost). Each session opens from the previous session's handoff and will close
with its own; a hook warns you at 70% and 80% of the context window (or the
custom CLAUDE_CONTEXT_WARN thresholds if configured). You are picking up the
baton from the previous session.

The hook also sends you informational checkpoints at 10, 20, 30, 40, 50 and
60% of the window: no action required and nothing to say to the user; use
them to PACE the session. With plenty of window left, work normally; from
around 50-60%, prefer finishing what is open over kicking off the largest
pending task, and factor the remaining window into any plan you propose (a
big refactor does not fit in the last 40% of a session). Do NOT write the
handoff early: closing is triggered only by the hook's close-out warnings or
by the user asking; a finished phase with window still available is a reason
to keep working, not to close.

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
   truth, resumable jobs). Close the summary with the two-line reminder of the
   cycle: the hook warns at 70% and 80% of the context window; at the first
   warning the session starts closing (no new large tasks), and it will end
   with a handoff (`/relevio:handoff`) plus a new session.
4. Then propose starting with the first pending item from the handoff and wait
   for the user's confirmation or their own direction. Do not start coding
   before that confirmation.
