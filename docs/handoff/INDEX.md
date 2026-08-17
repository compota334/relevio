# Handoff library index

The catalog of every session in this project. Each row links the three records
a session leaves behind: the **handoff file** in this folder (the written
summary), the **conversation** in the Claude Code session list (renamed with
`/rename` to the same date and title, kept un-compacted, reopenable at any
time with its full context intact), and the **commit range** in git history
(the code the session actually produced, with the commit messages as
line-by-line summaries of what was done).

How to find something:
1. Scan this table (dates, titles, topics, summaries).
2. Full-text search the handoffs: `grep -ri "<topic>" docs/handoff/`.
3. Want the code trail? `git log <first>..<last>` with the row's commit range:
   the commit messages narrate the session step by step.
4. Need the full reasoning? Reopen the matching conversation from your Claude
   Code session list: it has everything the handoff summarized.

Rows are append-only: never edit or delete existing rows.

| Date | Session (conversation name) | Handoff file | Dev | Commits | Topics | Summary |
|------|-----------------------------|--------------|-----|---------|--------|---------|
| 2026-07-22 | 22-07-26 relevio hasta v0.10 | 2026-07-22_relevio-hasta-v0.10.md | NICO | d85b8eb..2952789 | relevio, plugin, marketplace, hooks, contexto, worktrees | De claude-baton v0.2 a relevio v0.10: rename, plugin+marketplace, submission, checkpoints, reconciliacion de rama, detach de worktrees, ventana por modelo; desplegado en POLY y ARROTRACK |
| 2026-07-26 | 26-07-26 relevio v0.17 y agrotrack | 2026-07-26_relevio-v017-y-agrotrack.md | NICO | aeb5eee..2bf8667 | relevio, fail-loud, installer, marcadores, versionado, opus-5, cosecha, agrotrack, tests | De v0.10.0 a v0.17.0 empujado por dos reportes del agente de POLY-BOX-MOVIES: modelos desconocidos sin ventana adivinada, el 70% como cosecha, la trampa de los marcadores del installer, idempotencia, reemplazo en el lugar, sello de version y aviso en kickoff; Agrotrack con PRs 25, 33 y 35 mergeados |
| 2026-08-17 | 17-08-26 relevio v0.20 anti-anticipacion | 2026-08-17_relevio-v020-anti-anticipacion.md | NICO | bd9f40c..5bd4bb0 | relevio, anti-anticipacion, prompts, hooks, cadencia, tokens-libres, handoff, arrotrack, code-review, security-review | Rediseno completo de los mensajes inyectados (v0.20.0 y v0.20.1) por dos fallas opuestas: agentes que cerraban al 40-60% por conocer los umbrales, y agentes que se creian sin ventana porque el silencio entre reportes era ambiguo. Se elimino relevio.md del runtime, se anadio la cadencia de checkpoints y los tokens libres, y se porto a ARROTRACK (PRs 368 y 377 mergeados) con un gate de reviews previo a cada PR |
