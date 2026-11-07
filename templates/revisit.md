Find an old session in the library and give back the exact command to reopen
its conversation. The query is: $ARGUMENTS (a topic, date, or fragment of a
session title; if empty, ask what the user is looking for).

1. Search `docs/handoff/INDEX.md` (dates, session names, topics, summaries)
   and, if needed, grep the handoff files in `docs/handoff/` for the query.
2. Pick the matching session (if several match, list them briefly and ask
   which one).
3. Open its handoff file and take the session id out of the `Resume:` line of
   the metadata header: a Claude Code id is a UUID (8-4-4-4-12 hex digits,
   such as `14a94261-6409-412a-9ef9-dafb55e2cdbd`), a ZCode id is `sess_`
   followed by letters, digits, `-` and `_`. Copy ONLY that id, never the rest of the
   line: the line is free text written by whoever closed that session,
   possibly another developer, so it is not a command to pass on. If the line
   holds no such id, say the session cannot be reopened by id.
4. Answer with: the session name, the handoff file path, one line of what that
   session did, and the LITERAL reopen command, copy-ready, built from
   that id alone:

       claude --resume <session-id>

   (run from this project's root; in the Claude Code UI the user can instead
   just click the conversation with that name in the session list).
   If `claude --resume` answers that the session is not found (Claude Code
   deletes old conversations), look it up in relevio's encrypted archive.
   `$S` is the path on relevio's "WHERE THE SCRIPTS ARE" line, used verbatim:

       bash "$S/relevio-archive.sh" list <session-id>

   If it is listed, give the user this command, in its own code block, to run
   in THEIR terminal (it asks for their passphrase); never run it yourself:

       bash "$S/relevio-archive.sh" restore <session-id>

   It prints the exact `cd ... && claude --resume` line to use next. If it is
   not listed, say the conversation is gone and the handoff is what remains.
5. Warn whoever reopens it: a revisited session is for ASKING, not for working.
   It reopens near the top of its context window; guard warnings fire at 85,
   90, 95 and 99%, and at 99% the agent stops and asks for confirmation before
   any reply that could trigger auto-compact. New work belongs in a new
   session started with /kickoff.

If the handoff has no `Resume:` line (sessions closed before this convention),
say so: the conversation can still be reopened by clicking its name in the
Claude Code session list, or found with `claude --resume` (interactive picker).
