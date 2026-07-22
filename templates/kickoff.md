Open this session following the "Sessions and handoffs" convention in
CLAUDE.md: you are picking up the baton from the previous session.

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
   cycle: a hook warns at 70% and 80% of the context window (or the custom
   CLAUDE_CONTEXT_WARN thresholds if configured); at the first warning the
   session starts closing, and it will end with a handoff plus a new session.
4. Then propose starting with the first pending item from the handoff and wait
   for the user's confirmation or their own direction. Do not start coding
   before that confirmation.
