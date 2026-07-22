---
description: Close a session - write the dated handoff, update the index, hand over the close-out steps
---

Write a handoff for the next agent: you are passing the baton. Sessions close
BEFORE auto-compact so the conversation keeps its full context and stays
reopenable; the handoff is the written memory the next session starts from.

The folder is `docs/handoff/` (create it if it does not exist).
Naming: `YYYY-MM-DD_<short-title>.md`, where `<short-title>` is a short
kebab-case slug of what the session did, the SAME title the session name
carries (postmortem-style: date plus topic). No author and no "handoff"
suffix in the filename: the folder already says what it is, and the author
belongs in the metadata header below. Only if that exact filename already
exists (same date, same title), append the next letter in alphabetical order
(`_B`, `_C`, ...) to keep them ordered.

Start the file with this metadata header, every field filled:

    Session: DD-MM-YY <short title>
    Date: YYYY-MM-DD
    Dev: NAME (the dev's short name, uppercase; ask if you do not know it)
    Branch: <git branch the session worked on>
    Commits: <first hash>..<last hash> (or "none")
    Resume: claude --resume <session-id>
    Topics: <comma-separated lowercase tags>
    Summary: <one line>

To find <session-id>: this session's transcript is the most recently modified
`.jsonl` file in `~/.claude/projects/<slug>/`, where `<slug>` is this
project's absolute path with every `/` replaced by `-`; the filename without
`.jsonl` is the session id. The `Resume:` command lets anyone (human or
operator agent) reopen this exact conversation later, from this project's
root, with its full context intact.

`Session` is the exact name this conversation will get with `/rename` (you
build it: date plus a short title of what was done). It ties the handoff to
the conversation in the Claude Code session list, so anyone reading the
handoff later can find and reopen the original conversation, with its full
context, for questions.

Then write the body: general context, what we have done (with commit hashes),
the main files touched, and the lessons learned. Pay attention to any problem
that was hard to solve (several tries and errors) and could teach something
for similar future situations, but only if such a problem actually existed; do
not invent one. Do not repeat what the project's CLAUDE.md already says: the
next agent reads it too. Be thorough: we need a long, good handoff. Structure
it as a funnel, from general to specific, closing with the full picture. If
you received a previous handoff, fold in whatever is still relevant so the
next agent gets complete context. Handoffs ACCUMULATE: never delete or
overwrite older ones (that is why they carry dates); yours becomes the new
starting point and the old ones remain as history.

Also record any operational state that git does not capture: services or jobs
left running, which database or environment is the source of truth right now,
and any long process in progress with the information needed to resume it.

After writing the handoff, update the library index `docs/handoff/INDEX.md`:
append ONE row to the table with the same data as the metadata header (Date,
Session, Handoff file, Dev, Commits, Topics, Summary). The Commits column carries
the same `<first>..<last>` range as the header, so from the index anyone can
run `git log <first>..<last>` and read the session's work commit by commit.
If INDEX.md does not exist, create it by copying the relevio template
(https://github.com/compota334/relevio/blob/main/templates/INDEX.md).
Rows are append-only: never edit or delete existing rows.

Finally, close with LITERAL instructions the user can copy (assume an
inexperienced user):
1. Commit and push all verified work (if the machine has more than one GitHub
   account, check first that the active one is correct for this repo). This is
   what makes the handoff visible to the next session, so it MUST happen before
   the later steps. Say which branch you pushed to.
2. If this session runs inside a git worktree (check: the path from
   `git rev-parse --git-dir` contains `/worktrees/`), release the branch NOW,
   AFTER the push succeeded: run `git switch --detach`. Git allows a branch to
   be checked out in only one worktree, so without this the branch stays
   locked for every future session. Detaching frees it instantly while the
   worktree directory stays alive, pinned at this session's final commit, so
   this conversation remains revisitable. Tell the user you did it.
3. Close with TWO commands, and put EACH in its own fenced code block so the
   user copies it in one click, never buried inline in a sentence:
   - To rename this session: say "Copy and paste this into this same chat and
     press Enter:" then a code block with `/rename <the exact Session name from
     the header>` (only the human can rename).
   - To open the next one: say "Then close this conversation, open a NEW one, and
     paste this as the first message:" then a code block with just
     `/relevio:kickoff` (it already finds and reads the latest handoff on its
     own). Apart from the block, state the branch this session worked on and the
     handoff file, so the next session can reconcile even if it opens on a
     different branch: e.g. "This session worked on branch `<branch>` (handoff
     `docs/handoff/<file just created>`); /relevio:kickoff will read it and
     confirm the branch with you before continuing."

After this close-out, if the user asks you to write or edit MORE code in this
same session: do NOT code in place. If you detached in step 2 you are on a
detached HEAD, where new commits belong to no branch and get silently lost.
Re-establish a branch first (a fresh worktree, or ask the user where to work),
and remind them that new work belongs in a new session started with
/relevio:kickoff.

If the "user" is itself an operator agent driving Claude Code, these close-out
instructions are for IT to execute, not to display: it sends the `/rename`,
closes the session, opens a new one, and sends `/relevio:kickoff`.
