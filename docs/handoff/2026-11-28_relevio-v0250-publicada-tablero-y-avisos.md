Session: 28-11-26 relevio v0.25.0 publicada, tablero y avisos
Date: 2026-11-28
Dev: NICO
Branch: index-merged-by-content
Commits: ee24c71..f0504e2
Areas: README.md, scripts/relevio-handoffs-lib.sh, scripts/relevio-trace.sh, tests/install.sh
Resume: claude --resume 091be7d2-f4e7-4942-8848-3c751d7f2b67
Topics: relevio, release, v0.24.8, v0.25.0, merge, tablero, patch-id, git-cherry, commit-vacio, trace, context-warn, zcode, revisiones
Summary: PR #2 mergeado y releases v0.24.8 y v0.25.0 publicadas; las ramas del tablero por contenido (PR #3) y de los avisos de 85-99% (PR #4) pasaron las tres revisiones con arreglos y quedaron con PR abierto

# relevio v0.25.0 publicada; PR #3 (tablero) y PR #4 (avisos) abiertos

## 1. Contexto general

Es la misma conversacion que el handoff
`2026-11-28_relevio-v0250-pr-listo-tablero-y-avisos.md` (rama
`session-archive`, ya mergeada). Despues de ese handoff NICO pidio seguir
trabajando en la misma sesion: "1- MEREGALO. 2- HAGMOS LOS RELEASES. 3-
ENCARGUEMEONSOS DE ESO". Este handoff cubre ese segundo tramo y vive en la
rama `index-merged-by-content`, porque `session-archive` ya esta en main y
el handoff tiene que viajar dentro de un PR abierto (PR #3).

La cabecera solo cuenta los commits de esta rama. Los de la otra rama de
este tramo, `context-warn-window-full` (PR #4), estan en la seccion 2.4.

## 2. Lo que se hizo, en orden

### 2.1 Cuenta y forma de merge (preguntas a NICO)
- "Todo se hace como compota334 ... Confirmas la cuenta?" -> "Si,
  compota334". Todos los push, tags, releases y PR con el token de
  compota334 por comando; la cuenta activa de gh sigue en AIDeepEconomics.
- "Como mergeo el PR #2?" -> "Merge commit (Recommended)": los hashes de
  la rama llegan iguales a main, asi que los rangos `Commits:` de los
  handoffs de session-archive siguen resolviendo en main.

### 2.2 Releases y merge (sin commits de codigo)
- Tag anotado `v0.24.8` (mensaje "v0.24.8", como v0.24.7) sobre `9d58f47`
  y release `v0.24.8` con las notas del borrador.
- PR #2 mergeado con merge commit: `33ea9b4` (padres `9d58f47` y
  `339d2a0`). `session-archive` NO se borro (regla: las ramas no se borran).
- Tag `v0.25.0` sobre `33ea9b4` y release `v0.25.0`, marcada Latest. En
  las notas cambie el paso de setup: ya no da una ruta de script install
  (no sirve en plugin), dice que el asistente abre la terminal con
  `relevio-archive.sh setup` y nombra las dos rutas.
- Verificado: `VERSION` en main publicado dice 0.25.0 (curl a
  raw.githubusercontent).
- Borrador local de las notas: `docs/blueprints/2026-11-27_release-notes-v0248-v0250.md`.

### 2.3 Rama `index-merged-by-content` (PR #3)
- `cd1e2cf` merge de main (sin conflictos; mensaje en espanol).
- `3869d26` (/simplify): `lane_measure` reemplaza `branch_state` y
  `unmerged_count`. Deja `LANE_STATE`, `LANE_TIP` y `LANE_UNMERGED` en
  globales y se llama SIN `$( )`, asi un die corta el script. Atajo: una
  rama que es ancestro de main esta mergeada sin `git cherry` (medido:
  cherry cuesta 7-62 ms por rama contra 6-23 ms de merge-base, y crece con
  lo atrasada que esta la rama). El trace contaba "Commits touching" por
  hash; ahora cuenta los commits sin mergear que tocan la ruta, como el
  tablero (`git log --no-walk=unsorted <hashes> -- <ruta>`, verificado que
  respeta la ruta).
- `a077a40` (/code-review): un commit vacio (`--allow-empty`) no tiene
  patch-id y `git cherry` siempre lo lista con `+` (MEDIDO en un repo de
  prueba): la rama quedaba abierta aunque su trabajo estuviera en main.
  Ahora se ignoran los commits que no cambian nada (`git diff-tree --quiet
  --root -r`; un error de diff-tree corta con mensaje).
- `f0504e2` (/security-review): sin hallazgos; los errores nuevos muestran
  el nombre de rama con `relevio_safe` (regla propia del lib).
- 698 casos en verde. Medido en el repo real: el tablero queda "No active
  lanes".
- PR #3: https://github.com/compota334/relevio/pull/3 (abierto, MERGEABLE).

### 2.4 Rama `context-warn-window-full` (PR #4)
- `d56420a` merge de main (sin conflictos).
- `f65f54b` (/simplify): el test genera el aviso del 99% una sola vez.
- `af6a5c7` (/code-review): el STOP del 99% decia "with automatic
  compaction off, as relevio sets it" en todos los hosts, pero
  `ensure_user_settings` sale antes en ZCode (relevio no toca la
  compactacion ahi). Ahora dice "on Claude Code" y "with compaction on" para
  el otro caso. Test nuevo.
- 696 casos en verde.
- PR #4: https://github.com/compota334/relevio/pull/4 (abierto, MERGEABLE).

## 3. Lecciones

1. **Un test que pasa con el codigo viejo no prueba nada, y esta vez paso
   dos veces seguidas por razones distintas.** (a) El commit vacio quedo
   ultimo y el rango del handoff de prueba apuntaba a el, asi que el trace
   no mostraba la fila (artefacto del test). (b) Con `cherry-pick
   --allow-empty` el commit vacio llegaba tambien a main y `git cherry` los
   emparejaba. El escenario real es que el vacio NO llega a main: se
   eligieron a mano los tres commits reales (`feat-rebased~3
   feat-rebased~1 feat-rebased`).
2. **Un revisor puede afirmar un defecto que no existe**: dijo que el trace
   se tragaba un fallo de `git cherry`; el test con un git falso mostro que
   el `set -e` de bash si actua en esa asignacion de nivel superior. Medir
   antes de "arreglar".
3. **Encadenar el commit con `&&` despues de la bateria no frena en rojo**
   si lo que va entre medio es `grep` (sale 0): `f65f54b` se commiteo con un
   rojo que resulto intermitente. Mirar el exit de la bateria antes.
4. **Test intermitente en main**: "archive: ... and that passphrase opens
   the archive afterwards (keys check)" dio una vez `passphrase_prompts=2`
   en vez de 1; dos corridas siguientes en verde. Probable: `pty-drive.py`
   cuenta dos veces el mismo pedido de age cuando la pantalla se redibuja
   (PASS_RE mira los ultimos 200 bytes de `pending`). Sin investigar.

## 4. Estado operativo que git no captura

- **main** en `33ea9b4` (v0.25.0). Releases publicadas: v0.24.8 y v0.25.0
  (Latest).
- **PR #3** (`index-merged-by-content`, `f0504e2` mas el commit de este
  handoff) y **PR #4** (`context-warn-window-full`, `af6a5c7`): abiertos,
  sin CI, mergeables. Tocan README y tests en zonas distintas.
- **Worktrees**: `.claude/worktrees/index-merged-by-content` y
  `.claude/worktrees/context-warn-window-full` (dentro de `.claude/`,
  ignorado por git). Al cerrar: `git switch --detach` en cada uno.
- **Checkout principal** `/home/no/VIBE/claude-baton` en `session-archive`
  (ya mergeada). La proxima sesion deberia pasar a `main`.
- **relevio instalado en este proyecto** (`.claude/`, a mano) es el de
  session-archive, sin el arreglo del tablero: su INDEX.md todavia muestra
  `disable-all-compaction` hasta que se mergee PR #3 y se reinstale.
- **Cuenta gh activa**: AIDeepEconomics (se desvia sola).

## 5. Pendiente, por prioridad

1. **Mergear PR #3 y PR #4** (NICO decide; recomendado merge commit como
   PR #2). Despues, release v0.25.1 con los dos (avisos y tablero), si
   NICO quiere.
2. **Llave `relevio-prueba` en el panel de B2**: la borra NICO.
3. **Medir lo que pasa con la ventana llena y la compactacion apagada**:
   el PR #4 dice "fails as too long" sin haberlo forzado (el refresh de
   OAuth no funciona en una config aislada). Si se consigue medir, ajustar
   la frase.
4. **Test intermitente de pty-drive** (leccion 4).
5. **Propuestas sin decidir**: `git merge-tree --write-tree` para que un
   squash merge tambien salga del tablero (git >= 2.38, cambia el metodo
   aprobado); md5 y sha1 por fila en la copia en vez de `remote_hash` por
   copia (handoff anterior, 2.4).
6. Siguen de antes: Drive nativo, equipos, test del camino exitoso de
   `remote connect`, RFC 3161, la capa `~/.claude.json`, un "doctor" de
   compactacion, E5, off_notice para Devin, RAG, medir el negocio, ramas
   locales viejas (`retention`, `disable-all-compaction`,
   `claude/project-check-f091c8`).

## 6. Cuadro completo

relevio v0.25.0 esta publicada: el archivo encriptado de conversaciones,
con copia fuera de la PC y sellos en Bitcoin, ya es la version Latest en
GitHub, y v0.24.8 (la que apaga la compactacion) tiene por fin su tag y su
release. Quedan dos PR chicos y revisados: el tablero que reconoce como
mergeada una rama que entro por rebase (y no la deja abierta por un commit
vacio), y los avisos de fin de ventana que dicen lo que de verdad pasa, con
la salvedad de ZCode. Lo unico sin medir es que el mensaje falle por largo
con la compactacion apagada.
