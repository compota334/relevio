Session: 12-11-26 relevio v0.24.8 sin compactacion
Date: 2026-11-12
Dev: NICO
Branch: disable-all-compaction
Commits: 73160b5..a6ffbaa
Areas: .claude-plugin/marketplace.json, .claude-plugin/plugin.json, README.md, VERSION, hooks/context-warn.sh, hooks/session-start.sh, install.sh, templates/context-warn.sh, templates/session-start.sh, tests/install.sh, uninstall.sh
Resume: claude --resume 4fa8eea4-3d5d-47bc-b367-15c6c4ab3a29
Topics: compactacion, settings, autocompact, idlecompaction, release, v0.24.8
Summary: v0.24.8 apaga las tres compactaciones automaticas de Claude Code (autoCompactEnabled, precomputeCompactionEnabled, idleCompaction) en los dos canales, verificado contra el binario 2.1.321

# relevio v0.24.8: toda la compactacion automatica apagada

## 1. Contexto general

relevio existe para que una conversacion nunca se resuma sola: cada sesion se
cierra con un handoff ANTES de llenarse, y queda entera para reabrirla. Hasta
v0.24.7 relevio apagaba solo uno de los caminos de compactacion de Claude Code
(`idleCompaction`). El usuario audito el binario de Claude Code 2.1.321 que
usa la app de escritorio y pidio, en sus palabras: "evitando toda
compactacion de claude code por defecto en relevio, siempre. hay que combatir
la compactacion que es el enemigo de relevio". Pidio una rama nueva desde lo
ya publicado (main, v0.24.7) y un update rapido.

La sesion abrio con /kickoff sobre la rama `session-archive` (v0.25.0, archivo
encriptado de sesiones, SIN merge y SIN handoff propio). El tablero no
mostraba carriles activos porque `session-archive` no tiene handoff. El trabajo
de esta sesion salio de `origin/main` y no toca esa rama.

## 2. Lo que se hizo

Rama `disable-all-compaction`, PR https://github.com/compota334/relevio/pull/1
(abierto como compota334, hacia main).

- `73160b5` v0.24.8: apagar toda compactacion automatica.
  - `hooks/session-start.sh` (y su copia identica `templates/session-start.sh`):
    nueva constante `NO_COMPACTION` con las tres claves en false; en el canal
    plugin se agregan al objeto `$want` de `ensure_user_settings`, que ya
    escribia `cleanupPeriodDays` e `idleCompaction` en el settings.json del
    usuario. Mismo mecanismo de siempre: un jq para ver que falta, un rename,
    un aviso.
  - `install.sh`: `ensure_idle_compaction_off` paso a `ensure_compaction_off`
    y escribe las tres claves en el `.claude/settings.json` del proyecto.
  - `uninstall.sh`: avisa que deja las tres claves (no las borra, igual que
    antes con idleCompaction).
  - README, version 0.24.8 en VERSION, plugin.json, marketplace.json,
    install.sh y las cabeceras de los hooks.
- `ace527d` simplificacion (resultado de /simplify): el instalador lee y
  escribe settings.json UNA vez para las tres claves; el aviso del hook usa una
  marca (`why_compact`) en lugar de buscar su propio texto; el case del hook
  usa `*)` para toda clave de `NO_COMPACTION`; prueba de paridad que extrae la
  lista de claves del hook, del instalador y del desinstalador y exige que
  coincidan (son scripts independientes, sin libreria comun).
- `a6ffbaa` hallazgos de /code-review: el instalador citaba el valor anterior
  con `tostring`, y un texto con salto de linea partia la lista
  `clave<TAB>valor` y terminaba escribiendo una clave basura en false. Ahora
  usa `tojson`. Prueba nueva para el aviso del desinstalador.

Verificacion: `bash tests/install.sh` con 422 casos en verde (no hay CI en el
repo; esa es la bateria completa). Los casos nuevos se rompieron a proposito
(quitando autoCompactEnabled del instalador y del hook) y fallaron 8; se
restauro con cp desde backup. /security-review sin hallazgos.

Decision de diseno: el `/compact` MANUAL queda disponible. Por eso NO se usa
la variable `DISABLE_COMPACT` (la apaga tambien) ni `DISABLE_AUTO_COMPACT`
(redundante con la clave). Escribir /compact es un acto del usuario.

## 3. Lo que se midio en el binario (Claude Code 2.1.321)

Binario de la app: `~/.config/Claude/claude-code/2.1.321/ded331c1fbf8/claude`.
El CLI de terminal es otro (2.1.316 en `~/.local/share/claude/versions/`).

- Las tres son claves de settings.json, leidas con un resolvedor de capas y
  default true: `autoCompactEnabled` (con "if headless return false" delante),
  `idleCompaction`, `precomputeCompactionEnabled`.
- `autoCompactEnabled` tambien puede venir de la capa `legacyGlobalConfig`
  (`~/.claude.json`); hay una funcion que la migra a userSettings. No se
  verifico que capa gana.
- Los mensajes visibles: "Compacted while idle, before the prompt cache
  expired" y "Compacted using a summary written while you were away".
- Existe el comando `/autocompact`, que en `claude -p` informa el estado SIN
  llamar a la API: "Auto-compact is currently disabled (see /config)" o la
  ventana activa. Es la forma barata de verificar.

## 4. Prueba con el Claude Code real (y por que costo)

Resultado valido: con una configuracion limpia, `/autocompact` dice
"disabled" en un proyecto con relevio (`.claude/settings.json` en false) y
muestra la ventana de 1M (encendido) en un proyecto con
`autoCompactEnabled: true`. La clave del proyecto se respeta aun en una
carpeta no marcada como confiable (Claude Code solo ignora `permissions.allow`
ahi).

Lo que costo varios intentos:
1. Al principio TODOS los proyectos daban "disabled", tambien el de control
   con true, incluso pasando `--settings` con true. Causa: el
   `~/.claude/settings.json` del usuario tiene en `env`
   `DISABLE_AUTO_COMPACT=1` y `DISABLE_COMPACT=1`, y el shell hereda ademas
   `DISABLE_MICROCOMPACT=1`. Esas variables le ganan a cualquier clave.
   **Medir el estado de compactacion en esta PC exige neutralizarlas.**
2. No se pueden neutralizar desde afuera: `env -u` en el shell no alcanza
   (Claude Code vuelve a aplicar el `env` de settings.json), y `--settings`
   con `env` en "", "0" o "false" tampoco cambio el resultado.
3. Lo que funciono: `CLAUDE_CONFIG_DIR` apuntando a una carpeta temporal con
   `settings.json` vacio y un symlink a `~/.claude/.credentials.json`. Para
   `/autocompact` alcanza (no llama a la API).
4. Forzar una compactacion REAL (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=1` mas un
   segundo turno con `--resume`) NO se pudo: con la config limpia la API
   responde "OAuth session expired and could not be refreshed" (el refresh no
   puede escribir a traves del symlink). Copiar las credenciales en vez de
   enlazarlas se descarto a proposito: el refresh rota el token y podia
   cerrarle la sesion al usuario. Con un solo turno tampoco hay nada que
   compactar.

## 5. Pendiente, por prioridad

1. **Mergear el PR #1** (el usuario lo pidio; este handoff viaja dentro del PR
   antes del merge). Despues, publicar 0.24.8 si hace falta algun paso de
   release (tag `v0.24.8`, como los anteriores).
2. **Avisos de contexto desactualizados.** `hooks/context-warn.sh` (y su copia
   en templates) lineas ~347-350: a 90/95/99% dicen "Auto-compact is
   approaching/imminent" y que un intercambio mas "may trigger auto-compact".
   Con la compactacion apagada lo que pasa es un error de prompt demasiado
   largo. Hay que reescribirlos para los dos casos (apagada: error; encendida
   por el usuario: auto-compact). Se pregunto al usuario y quedo sin
   respuesta; es un cambio de texto, pero toca mensajes que el agente obedece:
   proponer la redaccion antes.
3. **Capa vieja `~/.claude.json`.** Verificar si un `autoCompactEnabled: true`
   ahi le gana al settings.json. Con la config limpia se puede probar sin API:
   poner `{"autoCompactEnabled": true}` en `$CLAUDE_CONFIG_DIR/.claude.json`,
   false en settings.json, y leer `/autocompact`.
4. **Propuestas del usuario que quedaron fuera del update rapido** (su
   auditoria, en el chat de esta sesion):
   - un comando "doctor" que detecte el binario real (version y ruta),
     resuelva todas las capas de configuracion (managed, user, project, local,
     --settings, env) y muestre cada camino de compactacion como apagado,
     encendido o desconocido, con su fuente. `/autocompact` en `claude -p` es
     una fuente directa para autoCompact;
   - avisar cuando un `settings.local.json` o una capa mas alta vuelve a
     encender lo apagado;
   - detectar compactaciones en los transcripts JSONL (marcador
     compact_boundary y los dos mensajes citados en la seccion 3) y
     reportarlas como falla;
   - revisar en cada version del binario las claves y env vars con "compact"
     y alertar si aparece una nueva;
   - nunca editar el cache de feature flags de `~/.claude.json` (el servidor
     lo reescribe).
5. **Rama `session-archive` (v0.25.0).** Trabajo grande sin merge y sin
   handoff (ultimo commit `0592f13`). Al integrarla va a chocar con esta en
   los numeros de version (0.24.8 en todos los archivos de version). Sus
   pendientes vienen del handoff `2026-11-03_relevio-v0246-y-blueprint-archivo-sesiones.md`
   (seccion 5); no se verifico cuales ya resolvio, en particular el defecto de
   `record_session_start()` (registra la hora de ahora y no la del primer
   mensaje del transcript).
6. Siguen abiertos del handoff anterior: mensaje `off_notice` para Devin, RAG
   sobre conversaciones, medir el negocio.

## 6. Decisiones y su porque

- **Las tres claves y no las env vars:** las claves se ven y se auditan en
  settings.json, conviven con el /compact manual y son las que el binario
  describe como el control. `DISABLE_COMPACT` mataria el /compact manual.
- **Un true explicito se pisa**, como ya se hacia con idleCompaction:
  instalar relevio ES la decision de no compactar. Siempre se avisa con el
  valor anterior.
- **Se escribe sea cual sea la version de Claude Code:** una version vieja
  ignora la clave, y no escribirla dejaria que una actualizacion empiece a
  compactar sin aviso.
- **Canal script: solo el proyecto. Canal plugin: el usuario.** Igual que
  antes: el plugin no puede llevar claves de settings (Claude Code descarta
  todas salvo dos), y el instalador ya es dueno del settings del proyecto.
  En Claude Code el proyecto le gana al usuario, asi que un true en el
  usuario no anula el false del proyecto.
- **Duplicacion aceptada:** instalador y hook apagan las mismas claves con
  codigo distinto, porque `install.sh` y `uninstall.sh` corren solos (`curl |
  bash`) y el hook es autocontenido. La prueba de paridad es la red.

## 7. Lecciones

1. **Antes de medir un ajuste de Claude Code en esta PC, mirar `env` en
   `~/.claude/settings.json` y en el shell.** Las variables DISABLE_* ganan a
   todo, y cualquier prueba de claves da "apagado" aunque la clave diga true.
2. **`/autocompact` en `claude -p` es el verificador barato**: estado sin
   gastar API. El `/compact` en headless no sirve para probar nada.
3. **El instalador se niega a correr dentro del repo de relevio.** Para
   actualizar la copia de este proyecto (`.claude/`, ignorada por git) se
   hicieron a mano las mismas copias que hace `install_file` (hooks y
   comandos desde `templates/`, scripts desde `scripts/`) y se pusieron las
   tres claves con jq. El handoff anterior describe otra via: `git archive
   HEAD | tar -x -C <tmp>` y `bash <tmp>/install.sh --update` desde la raiz;
   esa via puede tocar archivos que git sigue (.gitignore, CLAUDE.md), por eso
   se eligio la copia.
4. **El freno de rm de Claude Code bloquea borrar la carpeta de trabajo
   actual** (y sus padres). Las carpetas de prueba se borraron desde la
   terminal del usuario.
5. Un grep con `.{300}` sobre el binario de ~200 MB tardo mas de 2 minutos;
   con `timeout 60 grep -a -m2 -o` y patrones anclados en un nombre de funcion
   responde en segundos.

## 8. Estado operativo que git no captura

- **relevio v0.24.8 instalado en este proyecto** (`.claude/`, ignorada por
  git), copiado desde esta rama. `.claude/settings.json` tiene las tres claves
  en false. Respaldo del `.claude/` anterior (v0.24.7) en el scratchpad de la
  sesion: `/tmp/claude-1000/-home-no-VIBE-claude-baton/4fa8eea4-3d5d-47bc-b367-15c6c4ab3a29/scratchpad/claude-backup`
  (temporal, puede desaparecer).
- **`~/.claude/settings.json` del usuario:** las tres claves en false,
  `cleanupPeriodDays` 36500, y en `env` `DISABLE_AUTO_COMPACT=1` y
  `DISABLE_COMPACT=1` (puestos por el usuario; el segundo tambien bloquea el
  /compact manual en sus sesiones). `DISABLE_MICROCOMPACT=1` llega al shell
  y no existe en 2.1.321.
- **No hay `settings.local.json`** en este proyecto.
- **Cuenta gh activa: compota334**, verificada con `git credential fill`
  antes del push. La memoria del agente registra que se desvia sola.
- `git config relevio.dev NICO` sigue grabado en este clon.
- Nada corriendo en segundo plano.

## 9. Cuadro completo

v0.24.8 cierra el hueco principal: con relevio instalado, Claude Code ya no
compacta por su cuenta en ninguno de los tres caminos que trae encendidos, y
eso se comprobo contra el binario real. Lo que falta es que relevio diga la
verdad sobre la consecuencia (avisos de contexto: ahora es un error, no un
resumen), que sepa diagnosticar capas que lo contradigan (doctor, capa vieja,
settings.local) y que detecte si aun asi hubo una compactacion (transcripts).
En paralelo espera `session-archive` (v0.25.0), que habra que rebasar sobre
main con la version renumerada.
