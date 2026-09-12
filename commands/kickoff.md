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
      relevio told you where its scripts are in the message it injected at
      session start, on the line beginning "WHERE THE SCRIPTS ARE". Use that
      path verbatim:

          S=<the path from relevio's "WHERE THE SCRIPTS ARE" line>
          bash "$S/relevio-index.sh"

      Do not try to derive that path from an environment variable: on some
      hosts (ZCode, measured) the shell your Bash tool opens has none. If the
      line is missing from your context, find the directory instead of
      guessing, and use whatever this prints as `$S`:

          for c in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/scripts" \
                   "$(git rev-parse --show-toplevel)/.claude/scripts" \
                   $(sed -n 's/.*"installPath": *"\([^"]*\)".*/\1/p' ~/.zcode/cli/plugins/installed_plugins.json 2>/dev/null | grep '/relevio/' | sed 's|$|/scripts|'); do
            [ -r "$c/relevio-index.sh" ] && { echo "$c"; break; }
          done

      If nothing is found, tell the user that relevio's scripts are not
      reachable from this session and STOP. Do NOT conclude the install is out
      of date, and do not hand-edit INDEX.md.

      When the script instead FAILS, it always says why, and the two kinds of
      failure need different answers. If it names a handoff FILE and a FIELD,
      that header is malformed: report both, and if it predates v0.22 propose
      `relevio-migrate.sh` (same `$S`) and wait for the user's OK. Never patch
      a handoff header silently, least of all another dev's. If it names a REF
      instead, relevio does not know which branch this project integrates into;
      it prints the one-line `git config relevio.main <branch>` that records
      the answer for every future session. Relay that line and let the user
      choose the branch. Do not set it yourself: which branch is "main" is
      theirs to decide, and it is written into their repository.
   c. Show the user the **Active lanes** table exactly as generated. That is
      the team board: one row per branch with open work, who owns it, which
      areas it touches, how far ahead of main it is.
   d. Your lane is your current branch: `git rev-parse --abbrev-ref HEAD`.
      Read the LAST catalog row whose `Branch` column equals it. If the file
      is in your working tree read it directly; otherwise read it from history:

          f=<the Handoff file cell>; c=$(git log --all --format='%H' -1 -- "docs/handoff/$f"); git show "$c:docs/handoff/$f"

   e. If NO row carries your branch (a brand new branch, or a detached HEAD),
      read the last handoff of the main branch instead and say plainly that
      that is what you did, and why. Never hand the user another lane's
      handoff as though it were their own.
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
4. Check whether relevio itself is out of date, and report it in one line.
   relevio told you at session start which version it is running, on the first
   line of its core message, and which channel installed it, on the line
   beginning "INSTALL CHANNEL". Compare that version with the published one:

       curl -fsSL --max-time 5 https://raw.githubusercontent.com/compota334/relevio/main/VERSION

   If the core was injected TWICE at session start (two "relevio vX.Y.Z: this
   project uses the relevio session cycle" messages, whatever command names
   they carry), say THAT first: a plugin and a script install are arming you
   in parallel, so the rules arrive twice and possibly in two different
   versions. Tell the user to keep one, either by disabling the plugin in the
   host's plugin manager or by removing the script install with
   `bash <relevio>/uninstall.sh`, which keeps `docs/handoff/`.

   Then say which of these is true, and nothing more elaborate:
   - **Same version**: one line confirming it is current. Do not belabour it.
   - **Behind**: information, not an alarm. Being one version behind is not an
     emergency. Behind by SEVERAL versions, or carrying no stamp at all, is
     worth insisting on before real work: a stale model table makes the hook
     report a context percentage that is simply wrong, so a session gets told
     to wrap up at "80%" while it is really at 17%, and nobody can tell from
     the inside that the number is a lie.

     How it upgrades depends on the channel relevio named. Giving the wrong
     one wastes the user's time on a command that does not apply:
     * **script installer**: `bash <relevio>/install.sh --update`, run from
       this project root. It refreshes only relevio's own files and never
       touches `CLAUDE.md`, which is yours.
     * **plugin**: through the HOST, never with `install.sh`. On ZCode:
       Settings -> Plugins -> relevio -> update, or uninstall and install it
       again if no update button is offered. On Claude Code: `/plugin`. Then
       open a NEW session, because hooks and commands are registered when a
       session starts, so this one keeps the old copy no matter what.
       Prepare that click path for the user and stop there. You may confirm
       the new version is really published (the `curl` above reads it straight
       from `main`). You may NOT install it yourself, and in particular NEVER
       edit the host's plugin directory by hand (`~/.zcode/cli/plugins/...`
       and its equivalents): it is the host's own transactional state, and a
       half-applied edit breaks plugin loading in every project, not just this
       one.
   - **Could not check** (no network, curl missing, request timed out): say
     that explicitly, alongside the installed version. Never let a failed
     check pass as "up to date": silence would be indistinguishable from a
     clean result.
HOST NOTE (ZCode): if this session runs inside ZCode rather than Claude Code,
every relevio command is unprefixed there: `/kickoff`, `/handoff`, `/revisit`
(never `/relevio:...`). ZCode has no `/rename` and no `claude --resume`:
sessions are renamed and reopened from ZCode's own session list.

5. Then propose starting with the first pending item from the handoff and wait
   for the user's confirmation or their own direction. Do not start coding
   before that confirmation.
