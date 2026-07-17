Find an old session in the library and give back the exact command to reopen
its conversation. The query is: $ARGUMENTS (a topic, date, or fragment of a
session title; if empty, ask what the user is looking for).

1. Search `docs/handoff/INDEX.md` (dates, session names, topics, summaries)
   and, if needed, grep the handoff files in `docs/handoff/` for the query.
2. Pick the matching session (if several match, list them briefly and ask
   which one).
3. Open its handoff file and read the `Resume:` line of the metadata header.
4. Answer with: the session name, the handoff file path, one line of what that
   session did, and the LITERAL reopen command, copy-ready:

       claude --resume <session-id>

   (run from this project's root; in the Claude Code UI the user can instead
   just click the conversation with that name in the session list).
5. Warn whoever reopens it: a revisited session is for ASKING, not for working.
   It reopens near the top of its context window; guard warnings fire at 85,
   90, 95 and 99%, and at 99% the agent stops and asks for confirmation before
   any reply that could trigger auto-compact. New work belongs in a new
   session started with /kickoff.

If the handoff has no `Resume:` line (sessions closed before this convention),
say so: the conversation can still be reopened by clicking its name in the
Claude Code session list, or found with `claude --resume` (interactive picker).