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

1. Read `docs/handoff/INDEX.md` if it exists (the catalog of all sessions),
   then read the most recent handoff in `docs/handoff/` (or the one the user
   points to). Do this BEFORE touching any code. If the folder does not exist
   yet, this is the project's first session: say so and skip to step 2.
2. Check git state BEFORE working: `git fetch origin`; report which branch you
   are on, whether it is up to date with its remote, and whether there is
   uncommitted work from a previous session. If it is not clear which branch
   to work on (or where to branch from), ASK the user before touching
   anything.
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
