Session: 22-07-26 relevio hasta v0.10
Date: 2026-07-22
Dev: NICO
Branch: main
Commits: d85b8eb..2952789
Areas: .claude-plugin, .gitignore, LICENSE, README.md, commands, hooks, install.sh, templates, uninstall.sh
Resume: claude --resume 5681463f-d5c3-41f9-86c7-39aaaae73d4d
Topics: relevio, plugin, marketplace, hooks, contexto, worktrees, branch-reconciliation, despliegues
Summary: De claude-baton v0.2 a relevio v0.10: rename completo, plugin de Claude Code con marketplace propio, submission al directorio de Anthropic, y cinco iteraciones de la metodología (checkpoints cada 10%, esquema de nombres postmortem, reconciliación de rama, liberación de worktrees, ventana de contexto por modelo), todo desplegado además en los proyectos POLY y ARROTRACK del usuario.

Branch note: trabajado vía worktree claude/project-check-f091c8, todo pusheado a main

## 1. Qué es este proyecto (vista de pájaro)

relevio (ex claude-baton) es un framework de metodología de sesiones para
Claude Code: un hook PostToolUse que le informa al agente su porcentaje de
ventana de contexto (checkpoints informativos 10-60%, avisos de cierre 70/80,
guardias 85-99 con STOP LAW), los comandos /kickoff, /handoff y /revisit, y
una sección de CLAUDE.md con las reglas de trabajo. Se distribuye por dos
vías: script installer (install.sh, por repo, team mode) y plugin de Claude
Code (el repo es a la vez plugin y marketplace propio; instalable con
/plugin marketplace add compota334/relevio + /plugin install relevio@relevio).
Repo: https://github.com/compota334/relevio (PÚBLICO, cuenta compota334).
Dueño: NICO (compota334@gmail.com para este repo; la máquina también tiene la
cuenta AIDeepEconomics para Agrotrack360).

## 2. Qué se hizo en esta sesión (con commits)

- d85b8eb: newlines finales en todos los archivos (limpieza inicial).
- ec5668c v0.3.0: convertido en plugin de Claude Code con marketplace propio
  (.claude-plugin/plugin.json + marketplace.json, hooks/hooks.json, commands/
  autocontenidos con namespace /relevio:). Autor compota334.
- 81f5daf v0.4.0: rename claude-baton → relevio. El nombre "baton" está
  saturado en el ecosistema (blader/baton, batonpass, baton-pass hacen casi lo
  mismo) y "claude" chocaba con la regla de marcas del formulario de plugins.
  GitHub redirige las URLs viejas. Marcadores de CLAUDE.md ahora relevio:start/end.
- b80f6ce v0.5.0: nombres de handoff estilo postmortem
  (YYYY-MM-DD_<titulo>.md, sin autor ni sufijo _handoff; Dev y Branch en el
  header; columna Dev en INDEX.md; regla de commits chicos y frecuentes).
- b1bcb2c v0.6.0 + 11a753d v0.6.1: checkpoints informativos cada 10% (10-60)
  en el hook, con regla de ritmo en CLAUDE.md/kickoff; y regla anti-handoff
  prematuro (el cierre lo dispara SOLO el aviso del hook o el usuario).
- f09e5c6 v0.7.0: hook SessionStart en el plugin (inyecta la metodología en
  cada sesión según source: startup/clear=resumen, resume=reglas de revisita,
  compact=rescate). Verificado empíricamente que los hooks NO llegan a los
  subagentes. Sección de subagentes en el README.
- 8388f65 v0.8.0: kickoff reconcilia la rama: busca el handoff más nuevo en
  TODAS las ramas (git log --all por fecha del nombre + git show del ref),
  chequea si el trabajo ya está en main (merge-base --is-ancestor) y PREGUNTA
  en qué rama seguir. El cierre declara rama y archivo. Motivo: los handoffs
  quedaban varados en feature branches y la sesión siguiente leía uno viejo.
- 43e0161 v0.9.0: liberar la branch al cerrar sesiones en worktrees: tras el
  push, git switch --detach suelta la rama (git permite una rama por worktree)
  dejando el worktree vivo para revisita. Kickoff maneja rama tomada y poda.
- 2952789 v0.10.0: ventana de contexto REAL por modelo. Bug grave: el hook
  asumía 200k; con Fable 5 (1M) al 30% real calculaba 148% y disparaba STOP
  LAW falso. Ahora: tabla por modelo (todos los actuales 1M salvo haiku 200k,
  según catálogo Anthropic 2026-06), fallback conservador 200k para
  desconocidos, y autocorrección con aviso si el uso supera el límite asumido.
  CLAUDE_CONTEXT_LIMIT explícito siempre gana.

Además: submission del plugin al directorio community de Anthropic (formulario
de Console, nombre "Relevio", solo claude code, licencia MIT, sin privacy
policy, contacto compota334@gmail.com), enviada por el usuario, pendiente de
review; el pipeline toma los commits nuevos automáticamente.

## 3. Archivos clave

templates/ (context-warn.sh, kickoff.md, handoff.md, revisit.md,
CLAUDE.md.section, INDEX.md) son la fuente para el script installer;
commands/ y hooks/ son sus equivalentes del plugin (handoff/kickoff/revisit
adaptados con namespace /relevio: y hooks/session-start.sh que solo existe en
el plugin). install.sh mantiene VERSION en sync con plugin.json y
marketplace.json (hoy 0.10.0). El hook del plugin debe ser SIEMPRE idéntico a
templates/context-warn.sh (cmp tras cada edición).

## 4. Lecciones aprendidas (costaron varios intentos)

- La cuenta activa de gh se DESVÍA sola a AIDeepEconomics, incluso a mitad de
  sesión; causó un push 403. Verificar SIEMPRE con
  `printf 'protocol=https\nhost=github.com\n\n' | gh auth git-credential get`
  antes de cada push (hay memoria persistente de esto).
- El porcentaje de contexto era mentira en modelos 1M: 148% de 200k = 296k =
  30% de 1M. La matemática del porcentaje imposible fue el diagnóstico.
- Git tranca una rama por worktree checkouteado; git switch --detach la libera
  sin matar el worktree (revisita intacta). Verificado empíricamente.
- install.sh se niega a correr dentro del propio repo relevio (guard del
  installer): para instalar relevio EN relevio hay que copiar a mano (así se
  hizo: .claude/ y CLAUDE.md locales gitignoreados, docs/handoff commiteado).
- Los hooks PostToolUse/SessionStart NO llegan a subagentes (verificado contra
  transcripts reales con 4 subagentes: cero inyecciones).

## 5. Despliegues en proyectos del usuario (estado al cierre)

- POLY-BIAS-BOT (compota334, privado): las 5 ramas (main, main-v2,
  POLY-BIAS-TWEET, POLY-BIAS-48ELON, POLY-BOX-MOVIES) con relevio v0.9 de
  metodología + hook v0.10; .claude/ y docs salieron del gitignore (el usuario
  autorizó commitear secretos: repo privado). Clones locales en
  /home/no/POLY/* todos en fast-forward limpio con origin.
- POLY-SCOUT (compota334): instalación local gitignoreada; CLAUDE.md custom en
  español con la metodología integrada a mano; hook v0.10.
- ARROTRACK = Agrotrack360 (cuenta AIDeepEconomics, AIDeep-Economics/
  Agrotrack360): NO usa la sección estándar; su CLAUDE.md custom conserva el
  esquema viejo de nombres CON autor (decisión del usuario). Recibió por PRs
  mergeados a main: reconciliación de rama (PR #7 adaptado), worktree-detach
  (PR #23) y hook v0.10 (PR #24). Todo por rama+PR según su política.

## 6. Pendientes (en orden)

1. Chequear el estado de la submission al directorio community (buscar
   "relevio" en anthropics/claude-plugins-community/.claude-plugin/marketplace.json;
   sync nocturno tras aprobación).
2. El campo Resume de los handoffs asume el .jsonl más reciente del proyecto;
   con varias sesiones paralelas puede señalar la equivocada. Idea: hook
   SessionStart podría persistir el session_id real en un archivo.
3. Considerar SessionStart también para el script installer (hoy solo plugin;
   el CLAUDE.md cubre a los usuarios del script, pero resume/compact no).
4. La carpeta local sigue siendo /home/no/VIBE/claude-baton; renombrarla a
   relevio cuando no haya sesiones activas (rompe worktrees abiertos).
5. Evaluar limpiar los worktrees viejos del repo (git worktree list).

## 7. Estado operativo que git no captura

- Cuenta gh activa al cierre: AIDeepEconomics (el usuario la pidió así tras el
  PR de ARROTRACK). Para pushear relevio: switch a compota334 primero.
- Submission del plugin: enviada, en review de Anthropic. Nada que hacer salvo
  esperar/chequear.
- Sesiones vivas del usuario con markers re-armados en /tmp (5ae9fbac de
  BOX-MOVIES, ee830fa4 de 48ELON): el hook v0.10 les habla con porcentaje real.
- Este worktree (claude/project-check-f091c8) queda en detached HEAD tras el
  cierre, con la rama liberada; la conversación se revisita ahí.

## 8. Foto global

relevio v0.10.0 está completo, publicado y dogfoodeado: el propio repo ahora
corre la metodología (esta es su primera entrada de handoff). Las dos vías de
instalación funcionan y están documentadas; los proyectos reales del usuario
lo corren en producción y ya encontraron y motivaron cinco mejoras de diseño.
Lo único abierto es la aprobación del directorio de Anthropic y los
refinamientos menores de la sección 6. La próxima sesión arranca con /kickoff
desde /home/no/VIBE/claude-baton.
