# relevio for teams

Part of the [relevio](../README.md) documentation. How several developers and
agents share one handoff history: one lane per branch, a generated board,
computed headers, the surface trace, and worktrees.

## One lane per branch, and a board for the team

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
  "Merged" and "ahead" are measured by content (`git cherry`), not by commit
  hash, so a PR merged with "Rebase and merge" leaves the board even though
  its commits reached main under new hashes. A squash merge folds the
  commits into one that matches none of them, so a squashed branch stays on
  the board until it is deleted.
- **Catalog**: every session ever closed, on any branch, oldest first.
- **Needs fixing** (only when there is something to fix): handoffs whose
  header is malformed and that exist only on OTHER developers' branches. They
  are left out of the catalog until their owner fixes them, and they do not
  stop the index. A malformed handoff in your own working tree, on the branch
  you have checked out, or on main still stops it, naming the file and the
  field: that one is yours to fix. Before v0.24.5 any malformed handoff anywhere
  stopped everyone, so one developer's slip froze the board for a whole team.

`/kickoff` reads the row for **your** branch. On a brand new branch there is no
such row, so it reads main's last handoff and says in plain words that it is
doing so, instead of handing you a stranger's lane as if it were yours.

Because the file is generated, nobody edits it and nobody resolves merge
conflicts on it. When git reports a conflict there, the fix is to rerun the
script and commit the result. The index on a feature branch legitimately lists
sessions from other branches: it is a view of the repository as you last
fetched it, not of your branch.

## The header is computed, not typed

Six of the nine header fields are facts, and agents writing them by hand got
them wrong in ways no parser can catch: copying the previous handoff's header
as a template, not knowing where their own session began, spelling the dev's
name differently each time, and taking the session id from "the newest
transcript in the project folder", which is the OTHER conversation whenever two
are open in one project. A wrong id is worse than a typo: it makes a live
session look archived the next time it is resumed.

So the session-start hook tells the agent its session id (the host's payload
carries it) and records, once per session, the time and the commit it started
on. The record lives in git's own directory (`.git/relevio/sessions/`), so it
is never committed and every worktree of the clone sees it; a restart keeps the
first record. At close-out `relevio-header.sh <session-id>` turns that into:

| Field | Where it comes from |
|-------|---------------------|
| `Date` | today |
| `Dev` | `git config relevio.dev`, set once per clone (the script asks for it, it never guesses) |
| `Branch` | the branch checked out (a detached HEAD is refused) |
| `Commits` | the commits on that branch that you committed since the session began; teammates' commits pulled in meanwhile are left out |
| `Areas` | the paths those commits touched |
| `Resume` | `claude --resume <id>`, or the `sess_` id on ZCode |

The agent writes only `Session`, `Topics` and `Summary`, which the script
prints as `<fill in: ...>` placeholders; the index refuses a header that still
holds one. A session that began before v0.24.5 has no record and no id line:
the script says so, and the agent asks the user for the start (`--since`) and,
if needed, records no id (`--no-session-id`) in the open.

One trade-off, stated plainly: a handoff survives only while git can reach it.
Delete an unmerged branch and its handoff leaves the index with it. Push and
merge, or lose it. That was already true when the index was hand-written, since
the row lived on that branch too.

## Repositories without a remote

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

## Tracing who touched a surface

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

## Worktrees and parallel sessions

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
remove`, never forced), and offers to prune detached leftovers. Before
choosing a branch at all, `/kickoff` maps every worktree (folder, branch or
detached, number of uncommitted files) and marks the one the session runs in,
so a branch still held by an earlier session, or work left uncommitted in
another folder, shows up at the start instead of at the first failed switch.
Uncommitted files in someone else's worktree are listed for the user to
decide about, never discarded.
