Session: 28-11-26 relevio v0.25.0 PR listo, tablero y avisos
Date: 2026-11-28
Dev: NICO
Branch: session-archive
Commits: 17285c9..a71c1fb
Areas: scripts/relevio-archive-remote.sh, scripts/relevio-archive-stamps.sh, scripts/relevio-archive.sh, tests/install.sh, tests/pty-drive.py
Resume: claude --resume 091be7d2-f4e7-4942-8848-3c751d7f2b67
Topics: relevio, archivo-encriptado, opentimestamps, proof, limpieza, revisiones, pr, release, tablero, patch-id, context-warn, modo-autonomo
Summary: Prueba de v0.25.0 cerrada (sello confirmado en Bitcoin, proof y proof-check), limpieza de B2 y Drive, tercera ronda de revisiones con sus arreglos, PR #2 fuera de borrador, borradores de las releases, y dos ramas nuevas desde main: tablero por contenido (patch-id) y avisos de 85-99% sin auto-compact

# relevio v0.25.0: PR listo, tablero por contenido y avisos sin auto-compact

## 1. Contexto general

relevio es la metodologia de sesiones de este repo (`compota334/relevio`,
publico). v0.25.0 (archivo encriptado de conversaciones, copia fuera de la
PC, sellos OpenTimestamps, setup guiado) vive en la rama `session-archive`,
con el PR #2 hacia main. La sesion anterior (handoff
`2026-11-26_relevio-v0250-prueba-real-con-backblaze-b2.md`) dejo la prueba
real con B2 pasada salvo el sello en Bitcoin, y pendientes: proof,
limpieza, revisiones de la regla 30, sacar el PR de borrador y la lista de
releases.

Esta sesion (27 y 28 de noviembre) arranco con /kickoff y el push del
handoff anterior; despues NICO la dejo en MODO AUTONOMO con un despertador
cada 15 minutos (cron de la sesion, se borra al cerrar) y pidio avanzar todo
lo posible hasta el handoff y el PR.

Hay TRES ramas con trabajo de esta sesion:
- `session-archive` (este handoff, PR #2): commits `17285c9`, `86307c1`, `a71c1fb`.
- `index-merged-by-content` (desde main, pusheada, SIN PR): `ee24c71`.
- `context-warn-window-full` (desde main, pusheada, SIN PR): `e157105`.
La cabecera solo cuenta los commits de `session-archive`; los otros dos
estan aca abajo.

## 2. Lo que se hizo, en orden

### 2.1 Kickoff y push (sin commit nuevo)
- Push de `9a089fe` (handoff anterior) como compota334, con el token de
  compota334 solo para ese comando (la cuenta activa de gh era
  AIDeepEconomics, otra vez).

### 2.2 proof y proof-check (sin commit)
- `stamp now` en la PC de prueba 1: "1 proven in Bitcoin". Bloque 977709
  (2026-11-26 20:43:39 UTC).
- `proof 715836ee-... --out .../proof`: carpeta con conversation.jsonl, salt,
  leaf, leaf.txt.ots y VERIFY.txt.
- `proof-check`: blockstream.info coincide; mempool.space no respondio (por
  diseno alcanza con uno). Huella de la conversacion identica a
  `original.sha256` (`6ae92af7...`).
- Controles propios: la instruccion manual de VERIFY.txt da el mismo hash
  que la hoja; una copia con una letra cambiada da "does NOT match" y exit 2.

### 2.3 Limpieza (sin commit; NICO confirmo cada parte)
- Pregunta: "What should I do with the test B2 bucket during cleanup?" ->
  "Delete the bucket". Hecho con `rclone purge` (borra versiones ocultas y
  el bucket; la lista de buckets quedo vacia) y `rclone config delete
  relevio-b2`. La llave de aplicacion `relevio-prueba` SIGUE en el panel de
  B2: la borra NICO (Application Keys -> Delete).
- Pregunta: "Should I delete the Drive test folders and
  /home/no/relevio-prueba now?" -> "Yes, delete both". `relevio-test` y
  `relevio-test2` estan en la papelera de Drive (se vacia sola a 30 dias);
  `/home/no/relevio-prueba/` borrada entera (tenia las claves de PRUEBA).
- El remote `relevio-gdrive` de rclone se dejo (sirve para Drive nativo).

### 2.4 Regla 30 sobre lo del 26-11 (`110d135^..HEAD`)
- **/simplify** (4 agentes; commit `17285c9`): `remote_hash_use` resuelve la
  herramienta md5/sha1 una vez (como SHA) y fija `R_HASH_LEN`; sale
  `hash_len` y una rama imposible; `remote_hash_detect` reusa `rc_list` y
  fija R_HASH sin subshell (se van los `|| exit 2`); `catalog_stamps` usa
  `sha_of` (es huella local); fuera los `unset main` previos a un die.
  Verificado rompiendo el largo de sha1 a proposito: 21 casos rojos.
- **/code-review** (high, 8 hallazgos; commit `86307c1`):
  - ARREGLADO: `stamp setup` encendia los sellos ANTES del lock; con el lock
    ocupado moria con "proba de nuevo" dejando stamping=on. Ahora el lock va
    primero. Test nuevo en el caso 22.
  - ARREGLADO: un "not found" de rclone en `backend features` terminaba en
    "el proveedor no guarda md5 ni sha1" (rc_list lo lee como listado
    vacio). Ahora dice la razon real. Test nuevo en el caso 21 (rclone falso
    con `FAKE_FEATURES_NOTFOUND`).
  - ARREGLADO: pty-drive.py reporta 128+senal.
  - NO CAMBIA: `status` muere si el config no tiene `remote_hash`; es la
    ultima linea que imprime y el mensaje es claro (falla fuerte a
    proposito).
  - SALTEADO, propuesta aparte: guardar md5 Y sha1 por fila en remote.tsv y
    leer lo que el proveedor reporte (`rclone lsjson -R --hash`), en vez de
    fijar `remote_hash` por copia. Ventaja: si alguien repunta el remote de
    rclone a otro backend, nada se rompe; hoy push falla con "hash
    unsupported" y la salida (`remote set`) resetea los registros. Es un
    rediseno: no se hizo sin OK.
  - SALTEADO: las opciones `--recovery-file` y `--save-recovery` de
    pty-drive.py (sin test, pero sirven para manejar archivos de prueba a
    mano); el PATH global del caso 21 (legibilidad, no rompe hoy).
- **/security-review**: sin hallazgos de confianza >= 8 (eleccion de suma
  hecha localmente, md5/sha1 solo confirman la subida, sha256 y el sello de
  llaves siguen siendo la defensa; la llave principal en memoria es local,
  no exportada, nunca en la linea de comandos).
- Batería completa: 693 casos en verde, 0 salteados. Cada test nuevo dio
  rojo con el codigo viejo (restaurado con cp y cmp).

### 2.5 Linea de keys check al final del setup (`a71c1fb`)
- Pregunta: "Should setup end with one line suggesting keys check...?" ->
  "Yes, add it (Recommended)". El cierre del setup dice ahora que no pidio
  la contrasena una tercera vez, que todavia no la probo, y pide `keys check`
  y `keys check --recovery`. Test nuevo. Sale un `unset main` muerto.

### 2.6 PR #2 fuera de borrador (sin commit)
- https://github.com/compota334/relevio/pull/2, ready for review, cuerpo
  actualizado con la prueba B2, sus arreglos y la tercera ronda.
- OJO: `gh pr edit --body-file` NO guardo el cuerpo (error de "Projects
  (classic)" en GraphQL, salida con exit 0 aparente). Se uso
  `gh api -X PATCH repos/compota334/relevio/pulls/2 -F body=@archivo` y se
  verifico leyendo el cuerpo.
- No hay CI en el repo: la bateria es `bash tests/install.sh`.

### 2.7 Borradores de releases (sin commit, archivo local)
- `docs/blueprints/2026-11-27_release-notes-v0248-v0250.md` (excluido de git
  por `.git/info/exclude`): checklist en orden y notas en ingles para v0.24.8
  y v0.25.0, al estilo de v0.24.7 (titulo = tag, "What changed",
  "Upgrading"). NADA publicado.

### 2.8 Rama `index-merged-by-content` (`ee24c71`, desde main)
- Pregunta: extra work -> "Board fix (Recommended), context-warn texts".
- El tablero decidia "mergeada" con `merge-base --is-ancestor`. PR #1 se
  mergeo con "Rebase and merge" (medido: `git cherry origin/main
  origin/disable-all-compaction` da 4 lineas `-`), asi que la rama seguia
  "abierta, 4 ahead".
- `unmerged_count` en `scripts/relevio-handoffs-lib.sh`: `git cherry` (un
  patch-id por commit, ignora merges). `branch_state` (tablero y trace) y la
  columna "Ahead of main" cuentan lo mismo. Un fallo de git cherry se pasa
  con `|| exit 2` en cada nivel (ver leccion 1).
- Alternativa considerada: `git merge-tree --write-tree` (merged si mezclar
  no cambia el arbol de main): cubre tambien squash, pero exige git >= 2.38.
  Se eligio patch-id (lo que NICO aprobo). Limite documentado en el README:
  un squash merge sigue apareciendo abierto.
- Tests: rama mergeada por rebase sale del tablero (con guarda de que los
  hashes son NUEVOS), rama mergeada a medias queda con "ahead 2", trace las
  marca merged / OPEN WORK. Los 3 rojos con el codigo viejo.
- Medido en el repo real: `disable-all-compaction` desaparece del tablero.
  `session-archive` pasa de 43 a 42 "ahead" (no cuenta el merge de main).
- Batería en esa rama: 425 casos verde (la rama sale de main, no tiene los
  casos del archivo).
- Conflicto esperable con PR #2: ninguno en el lib (session-archive no lo
  toca); en `tests/install.sh` y README si, por cercania. Resolver al
  mergear la segunda.

### 2.9 Rama `context-warn-window-full` (`e157105`, desde main)
- Los avisos de 85/90/95/99% de `hooks/context-warn.sh` y
  `templates/context-warn.sh` (copias identicas, hay un test que lo exige)
  decian "auto-compact is approaching/imminent". Con la compactacion
  apagada (v0.24.8) lo que pasa es que el proximo mensaje falla por
  demasiado largo. Ahora: "the window is nearly full / about to fill /
  about to run out of room", y el STOP del 99% nombra los dos casos (apagada:
  falla; encendida por el usuario: se resume y pierde detalle). README
  alineado (tabla y seccion de /revisit).
- El handoff de v0.24.8 pedia "proponer la redaccion antes" porque el
  agente obedece estos mensajes: por eso quedo en su rama, SIN PR, para que
  NICO lea el texto (`git show e157105`).
- Tests: ninguna mencion de auto-compact entre 85 y 99%; el 99% dice "fails
  as too long" y "loses its remaining detail". Rojos con el codigo viejo.
- Conflicto esperable con PR #2: la linea 2 de los dos context-warn.sh
  (cabecera de version 0.25.0 en session-archive).

## 3. Lecciones

1. **`set -e` no entra en `$( )`** (sin `inherit_errexit`) y `board_rows`
   ya corre dentro de uno (`ROWS="$(board_rows)"`). Un `die` adentro solo
   termina ese subshell; `[ "$(f)" = open ] || continue` se traga el error.
   Cada nivel necesita `x="$(f)" || exit 2`. Es la misma leccion del 26-11
   con `remote_hash_detect`, ahora en otro archivo: buscarla en cada codigo
   nuevo que llame funciones que pueden morir.
2. **Un cherry-pick en el mismo segundo y sobre el mismo padre rehace EL
   MISMO commit** (mismo hash): el primer test de "mergeado por rebase"
   pasaba tambien con el codigo viejo. Hay que mover main antes y agregar una
   guarda en el test (`merge-base --is-ancestor` debe dar "new-hash").
3. **Los tests de context-warn instalan desde `templates/`**, no desde
   `hooks/`: romper solo `hooks/` para la prueba de rojo no rompe nada mas
   que el test de "copias identicas". Romper las dos.
4. **`gh pr edit` puede no guardar** con el error de Projects (classic):
   verificar leyendo el cuerpo; la API REST con PATCH si funciona.
5. **Un worktree borrado deja el shell sin carpeta** ("getcwd: cannot
   access parent directories"): usar `cd /ruta && ...` en el comando
   siguiente.

## 4. Estado operativo que git no captura

- **Ramas**: `session-archive` en `a71c1fb` (pusheada; mas el commit de este
  handoff). `index-merged-by-content` en `ee24c71` y
  `context-warn-window-full` en `e157105`, ambas pusheadas, sin PR, sin
  worktree (se liberaron con `git worktree remove` estando limpias).
- **PR #2**: abierto, listo para revisar, cuerpo actualizado. Sin CI.
- **Cuenta gh activa: AIDeepEconomics** (se desvia sola). Todos los push y
  la edicion del PR se hicieron como compota334 con su token por comando:
  `git -c credential.helper= -c 'credential.helper=!f(){ echo username=compota334; echo "password=$(gh auth token --user compota334)"; }; f' push ...`
  y `GH_TOKEN="$(gh auth token --user compota334)" gh ...`.
- **Archivo real `~/.relevio`**: sano, 1401 conversaciones, sin copia fuera
  de la PC ni sellos (nunca se toco en estas pruebas).
- **rclone**: solo queda el remote `relevio-gdrive` (scope drive.file).
- **Despertador**: cron `3e03356c` de esta sesion (cada 15 min); se borra al
  cerrar esta sesion. Muere solo con la sesion.
- **Borradores de releases**: `docs/blueprints/2026-11-27_release-notes-v0248-v0250.md` (local).

## 5. Pendiente, por prioridad

1. **Revisar y mergear el PR #2** (NICO). Estilo de merge: si se usa
   "Rebase and merge" como en PR #1, el arreglo del tablero (2.8) hace que
   `session-archive` salga sola del tablero.
2. **Releases**, en el orden del borrador: tag y release v0.24.8 sobre
   `9d58f47` (main), despues del merge del PR #2 tag y release v0.25.0. Solo
   con OK de NICO, como compota334.
3. **Las dos ramas nuevas**: NICO lee el texto de `e157105` (avisos) y el
   cambio de `ee24c71` (tablero). Con su OK: correr la regla 30 en cada una
   (/simplify, /code-review, /security-review, bateria) y abrir sus PR. Si
   PR #2 se mergea antes, traer main a cada rama y resolver los conflictos
   previstos (2.8 y 2.9).
4. **Llave de aplicacion `relevio-prueba` en el panel de B2**: la borra
   NICO.
5. **Propuesta sin decidir**: md5 y sha1 por fila en vez de `remote_hash`
   por copia (razonamiento en 2.4).
6. Siguen de antes: Drive nativo (app de relevio en Google), equipos
   (invitar, sacar, compartir de a una conversacion con revision de
   secretos), test del camino exitoso de `remote connect` (pty-drive.py mas
   un rclone falso como el de rclone-sha1), RFC 3161, la capa
   `~/.claude.json` (si un `autoCompactEnabled: true` ahi gana), un "doctor"
   de compactacion, E5 (SessionEnd en la app de escritorio), off_notice
   para Devin, RAG, medir el negocio, ramas locales viejas (`retention`,
   `disable-all-compaction`, `claude/project-check-f091c8`) que borra NICO
   si quiere.

## 6. Cuadro completo

v0.25.0 esta terminada y probada contra una nube real: una conversacion
salio encriptada, volvio identica a una PC vacia con cualquiera de las dos
llaves, y su sello quedo confirmado en el bloque 977709 de Bitcoin, con una
prueba que cualquiera puede verificar y que rechaza un byte cambiado. Las
pruebas se limpiaron (solo queda la llave de B2 en su panel, que borra
NICO). La tercera ronda de revisiones encontro y arreglo dos defectos
chicos, cada uno con su test, y el PR #2 esta listo para revisar, con los
borradores de las dos releases preparados y nada publicado. Aparte, dos
ramas desde main esperan la lectura de NICO: el tablero que ya no confunde
una rama mergeada por rebase con una abierta, y los avisos de fin de ventana
que dejan de prometer un auto-compact que relevio apago.
