Session: 15-10-26 relevio v0.22 a v0.24 equipos zcode compactacion
Date: 2026-10-15
Dev: NICO
Branch: claude/relevio-multi-branch-teams-be28b6
Commits: fde285a..0ddc6ec
Areas: .claude-plugin, README.md, VERSION, commands, docs, hooks, install.sh, scripts, templates, tests, uninstall.sh
Resume: claude --resume 14a94261-6409-412a-9ef9-dafb55e2cdbd
Topics: relevio, carriles, indice-generado, trace, migracion, zcode, idle-compaction, reinicio, cierre, release, seguridad
Summary: De v0.21.5 a v0.24.0 en una sesion larga: handoffs por carril para equipos, indice generado con tablero, rastreo de superficies, ZCode funcionando como plugin, el agente ya no cierra por su cuenta, reinicio distinto de archivo, idleCompaction apagado y primera release en GitHub

## 1. Contexto general

relevio es la metodologia de sesiones para agentes de IA (Claude Code y
ZCode) que vive en este repo: hooks que le informan al agente su uso de
ventana de contexto, un handoff escrito al cerrar cada sesion, y un archivo
de conversaciones nunca compactadas que se pueden reabrir. Se distribuye de
dos formas: como plugin (marketplace `compota334/relevio`, lee de main) y con
un instalador por script que copia todo a `.claude/` del proyecto.

Esta sesion arranco en v0.21.5 con una pregunta del usuario: relevio
funcionaba bien para una persona en una rama, pero se rompia con un equipo de
devs en varias ramas y worktrees, cada uno con sus agentes. Termino en
v0.24.0, con 30 commits, casi todos impulsados por reportes reales de los
agentes del usuario en otros proyectos (sobre todo Agrotrack360 y una sesion
de testing en ZCode). Todo esta pusheado a `main` en GitHub
(`compota334/relevio`, publico) y existe la primera release de GitHub:
v0.24.0, tag sobre `0ddc6ec`.

El repo es todo en ingles (codigo, README, mensajes al agente); los commits y
los handoffs van en castellano por convencion del usuario.

## 2. Lo que se hizo, version por version

Rango completo: `git log fde285a^..0ddc6ec` (los commits cuentan cada paso).

| Version | Commit | Que trajo |
|---|---|---|
| v0.22.0 | `3dc8f32` | Handoffs por carril: indice generado (`relevio-index.sh`) con tablero de carriles activos y catalogo, rastreo de superficies (`relevio-trace.sh`), migracion unica de cabeceras viejas (`relevio-migrate.sh`), campo `Areas` |
| v0.22.1 | `4a70835` | ZCode como plugin: los hooks se ubican a si mismos, anuncian donde estan los scripts, se invocan con `bash` |
| v0.22.2 | `9d3235c` | Cuatro hallazgos de revision: dos devs con el mismo nombre de archivo, la trampa del tab en IFS, aviso falso del instalador |
| v0.22.3 | `60cfee4` | Instrucciones de actualizacion segun el canal (plugin o script) |
| v0.22.4 | `7f42995` | `git config relevio.main <rama>` para repos sin remoto |
| v0.22.5 | `07c2820` | Regla en el nucleo: explicarle las cosas a un usuario que puede no ser programador |
| v0.22.6 | `ce001ff` | Rechazar `HEAD` como rama de integracion |
| v0.22.7 | `d7adad8` | README: los hooks corren sin bit de ejecucion |
| v0.22.8 | `8a89a1b` | ZCode manda el modelo compuesto (`builtin:zai/GLM-5.3-max`): se quita proveedor y nivel de esfuerzo; rechazo de reflogs (`HEAD@{1}`); `RELEVIO_DEBUG=1` |
| v0.22.9 | `6d614e5` | Cerrar la sesion no es decision del agente |
| v0.23.0 | `1eeae86` | Al terminar una tarea: resumen Done / Pending / Needs from you en vez de handoff |
| v0.23.1 | `222eb2a`, `d49092d` | Primer reporte en la primera llamada; raw-count ya no le entrega al agente la decision de cerrar; handoff pedido con palabras pasa por el comando; reinicio distinto de archivo (con arreglo de revision entre ramas) |
| v0.23.2 | `16a1dbd` | El indice descartaba handoffs en silencio con varios rotos (pipefail + grep -q); carpetas con espacios en `Areas` |
| v0.23.3 | `6a98f6e` | Copias sin cabecera en ramas viejas se perdonan por ruta; los errores nombran la rama |
| v0.23.4 | `73fbd17` | Perdonar una copia que fue alguna vez la version de main de ese archivo |
| v0.24.0 | `e59a5fd`, `3c9c61b` | `idleCompaction: false` en los dos canales, forzado aunque este en true |
| docs | `76637e3`, `0ddc6ec` | README: la frase de SEO sobre idle compaction en la intro, y diez pasajes desactualizados corregidos |

Suite de tests: `bash tests/install.sh`, 314 aserciones en verde al cierre.
No hay type-checker ni linter: el proyecto es bash y markdown.

## 3. Archivos principales

- `scripts/relevio-handoffs-lib.sh`: el corazon. Parser de cabeceras,
  escaneo de handoffs en todas las ramas, catalogo, reglas de supersesion,
  estado de ramas, `areas_for_range`, `replaced_on_main`.
- `scripts/relevio-index.sh`, `relevio-trace.sh`, `relevio-areas.sh`,
  `relevio-migrate.sh`: puntos de entrada sobre la libreria.
- `hooks/session-start.sh` y `hooks/context-warn.sh`, con gemelos byte a
  byte en `templates/` (un test lo exige).
- `commands/*.md` (canal plugin) y `templates/*.md` (canal script): forks
  deliberados, difieren solo en prefijos y notas de ZCode.
- `install.sh`, `uninstall.sh`, `README.md`, `tests/install.sh`.
- `docs/2026-08-26_zcode-investigation.md`: todo lo medido sobre ZCode.

## 4. Decisiones de diseno y su porque (lo que no se re-deriva gratis)

**Indice generado, nunca editado.** `INDEX.md` se reconstruye desde las
cabeceras de todos los handoffs en todas las ramas. Ante un conflicto de
merge en el, la regla es correr el script de nuevo, nunca resolver a mano.
Los carriles del tablero salen del campo `Branch:` de las cabeceras, no de
donde vive el archivo.

**Como se escanea.** Una ref por nombre de rama, prefiriendo la remota (una
`main` local desactualizada ya no resucita versiones viejas). Se deduplica
primero por contenido (path + blob) y despues por identidad de sesion (fecha,
nombre de conversacion, dev). Asi la misma sesion vista desde cinco ramas es
una fila, y dos devs que comparten nombre de archivo sobreviven los dos.

**Cuando se perdona una copia que no parsea** (las tres reglas, en
`load_catalog`):
1. su identidad coincide con una sesion indexada (copia vieja de la misma);
2. no tiene identidad completa y el mismo archivo se indexo desde otra rama
   (handoffs anteriores a la cabecera, del tipo `# Handoff - PROYECTO - FECHA`);
3. ese contenido fue alguna vez la version de main de ese archivo y main ya
   lo reemplazo (`replaced_on_main`, por historia de git).
Nunca se perdona la version actual de main rota ni una copia del working
tree. La sesion de otro dev que comparte nombre nunca estuvo en main, asi que
ninguna regla la tapa: esa es la proteccion que se rompio y se arreglo dos
veces.

**Rango de commits inclusivo.** `Commits: a..b` incluye `a`; git no. Todo
lo resuelve como `a^..b`. Por eso `relevio-areas.sh` existe: para que nadie
retipee la tuberia y pierda su primer commit.

**Ningun campo vacio en registros con tab.** El tab es espacio en blanco
para IFS, asi que bash colapsa tabs seguidos y un campo vacio corre todos los
siguientes. Regla escrita en la libreria: centinela `RELEVIO_NONE` (`-`) para
lo ausente, y separador `\037` (en la variable `US`) para los registros de
fallas.

**ZCode, todo medido** (detalle en el doc de investigacion):
- `CLAUDE_PLUGIN_ROOT` llega a los hooks pero NO a la shell del agente. Por
  eso los hooks se ubican a si mismos (`dirname BASH_SOURCE/../scripts`) y le
  anuncian la ruta al agente en la linea "WHERE THE SCRIPTS ARE".
- Instala los archivos del plugin sin bit de ejecucion: el manifiesto los
  invoca con `bash`, y toda verificacion usa `-r`, nunca `-x`.
- El modelo llega compuesto (`builtin:zai/GLM-5.3-max`); `-low/-high/-max`
  son niveles de esfuerzo segun la doc de Z.ai, no modelos.
- No tiene CLI de plugins: actualizar es Settings -> Plugins y sesion nueva.

**Quien cierra la sesion.** La leccion de v0.20 fue: nombrar los umbrales en
el nucleo hace que el agente cierre temprano. La de esta sesion: callar sobre
CUANDO no es callar sobre QUIEN. El nucleo ahora no nombra umbrales ni
ensena el procedimiento, pero dice que cerrar es decision del usuario (o de
un mensaje de relevio que lo diga con esas palabras), y que una tarea
terminada se reporta, no se cierra. El modo raw-count le decia al agente
"decidi cuando cerrar" cada 100k tokens; como todo ZCode corria en raw-count
antes del arreglo del modelo, esa era la causa mas probable de los cierres a
mitad de ventana que reporto el usuario.

**Reinicio vs archivo.** Una sesion esta cerrada si un handoff tiene su id
en el campo `Resume:`, buscado en todas las ramas y en el working tree. Si
ninguno la nombra, es un reinicio y el agente sigue. Limite conocido: si el
usuario pidio un handoff a mitad de sesion y despues siguio trabajando, un
reinicio posterior se ve como archivo.

**idleCompaction** (Claude Code v2.1.290+ compacta conversaciones inactivas
~1 hora): el script lo escribe en el `.claude/settings.json` del proyecto; el
plugin no puede traer la clave (Claude Code descarta todas las del plugin
salvo dos), asi que el hook de arranque la escribe en el settings del
usuario. Se fuerza a false aunque este en true (decision del usuario:
instalar relevio es elegir no compactar), sin importar la version, nunca a
traves de un symlink ni sobre JSON invalido, nunca en ZCode, y anunciandolo.
La suite fija `CLAUDE_CONFIG_DIR` en una carpeta temporal para no tocar el
settings real de quien la corre.

## 5. Lecciones aprendidas (problemas que costaron varios intentos)

1. **Fallar fuerte que fallaba abierto.** `... | grep -q FATAL && exit 2`
   bajo `set -o pipefail`: grep -q corta en la primera coincidencia, el bucle
   muere por SIGPIPE, la tuberia falla y el `exit 2` nunca corre. Con UN
   handoff roto andaba; con varios, reportaba exito y sobrescribia el indice
   sin esas sesiones (el reporte real: 405 de 468). Leccion: un test de
   "falla con un caso malo" no prueba "falla con N".
2. **Arreglos que rompieron repos reales.** v0.23.2 cambio la regla de
   perdon de ruta a identidad y rompio Agrotrack360 (434 copias sin cabecera
   en ramas viejas); v0.23.3 no cubria una copia con identidad completa pero
   distinta ("Dev: Enzo B" contra "Dev: ENZO"). Leccion: probar contra las
   formas reales de los archivos, no contra fixtures inventados, y verificar
   cada test de regresion contra la version publicada (debe fallar ahi).
3. **sed con `|` como delimitador se come la alternancia `\|`.** Ademas
   `\|` no existe en BRE de BSD. Usar `sed -E` con otro delimitador (`#`).
4. **Las pruebas a mano dentro del worktree borraron la instalacion local.**
   Comandos de prueba con `rm -rf .claude/hooks` en el worktree se llevaron
   la instalacion real de relevio de este worktree (la app de escritorio la
   volvio a copiar al reiniciar). Leccion: probar siempre en carpetas
   temporales, nunca en el `.claude/` del repo.
5. **La cuenta de gh se desvia sola**, en las dos direcciones, a veces en
   minutos. Ya esta en la memoria del agente: verificar la credencial real
   (`git credential fill`) justo antes de cada push.

## 6. Pendiente, por prioridad

1. **Decidir la v0.25.0.** Quedo propuesto, sin respuesta del usuario:
   - **Campos mecanicos calculados por relevio.** Los errores de handoff de
     un agente son de contexto, no de tipeo: copia la cabecera del handoff
     anterior como plantilla, no sabe donde empezo su sesion, inventa el
     nombre del dev distinto cada vez, y sobre todo deduce MAL su propio id
     de sesion. El comando `/handoff` le dice que tome el `.jsonl` mas
     recientemente modificado de la carpeta del proyecto, y esa carpeta
     guarda todas las sesiones del proyecto: con dos sesiones abiertas puede
     anotar el id de la otra, y eso rompe la deteccion de reinicios (la otra
     sesion, viva, pasaria por archivada). Los transcripts de subagentes NO
     contaminan: viven en `<sesion>/subagents/`. Propuesta: el hook de
     arranque le dice al agente su id (lo tiene en el payload) y anota la
     punta de la rama al empezar (en el directorio de git, sobrevive a
     reinicios, no se commitea); un script imprime la cabecera con Date,
     Dev (`git config relevio.dev`, una vez por clon), Branch, Commits,
     Areas y Resume ya completos; el agente llena solo Session, Topics,
     Summary y el cuerpo.
   - **Opcion B: te frena solo lo tuyo.** Un handoff roto en tu working
     tree, tu rama o main frena todo; uno roto solo en la rama de otro dev
     queda fuera del catalogo y aparece nombrado en una seccion "Necesita
     arreglo" del indice. Relaja la regla de fallar fuerte para ese caso, por
     eso la decision es del usuario. Motivo: hoy un handoff roto de ENZO le
     traba el tablero a todo el equipo de Agrotrack360.
   - El usuario descarto como overkill: un "doctor" con `--fix`, mensajes
     listos para mandarle a otro dev, y una barrera en el commit (hook
     PreToolUse sobre `git commit`).
2. **Aviso del host extranjero** (Devin y similares, sin `transcript_path`):
   el mensaje unico de `off_notice` en `hooks/context-warn.sh` todavia dice
   "use that knowledge to decide when to wrap up the session with a handoff",
   o sea le da al agente la decision de cerrar, el mismo error que se arreglo
   en raw-count en v0.23.1. Arreglo chico de texto: que avise al usuario y
   decida el. NO mide nada: relevio no tiene lector de uso para Devin, y
   medirlo de verdad es otro proyecto que empieza por investigar que expone.
   El README describe el comportamiento actual (fila "Foreign host, first
   tool call"), asi que cambiarlo requiere tocar los dos.
3. **Frase de las notas de la release**: dice "This is relevio's first tagged
   release", correcto pero confundio al usuario (parece que el proyecto es
   nuevo). Propuesta sin respuesta: "relevio has shipped from main for
   months; this is its first tagged release on GitHub".
4. **Agrotrack360** (`AIDeep-Economics/Agrotrack360`, privado, cuenta
   AIDeepEconomics): el handoff de ENZO en la rama
   `enzo-tareas-zafra-aprobacion-y-sesion-subagente`, archivo
   `docs/handoff/2026-10-14_tareas-zafra-aprobacion-sdk-y-memoria-de-subagentes.md`,
   traba el indice de todo el equipo. Arreglo de dos lineas en su rama:
   `Branch: enzo-tareas-zafra-aprobacion-y-sesion-subagente` (la rama vieja
   `enzo-identity-resolution` ya no existe, probable renombre) y
   `Commits: 6d924856b..94f9dab87` (son contiguos). `relevio-migrate.sh` NO
   lo arregla: una lista separada por comas no tiene rango del que partir.
   La causa raiz fue que ese repo estaba en 0.23.0 (sin la regla de usar el
   comando para un handoff pedido con palabras); el usuario ya instalo la
   0.24.0 ahi. Si en ese repo `.claude/` esta en git, hay que commitear y
   pushear la actualizacion para que le llegue a ENZO.
5. **Reforzar relevio contra inyeccion de prompt** (surgio al final, sin
   decision del usuario todavia). Un agente de otro proyecto parcheo
   localmente el kickoff para que la consulta de version
   (`curl .../main/VERSION`, cuyo resultado entra crudo al contexto del
   agente) solo acepte algo con forma semver y descarte lo demas como
   "unreachable". Propuesta, las tres chicas:
   - adoptar oficialmente ese chequeo semver en `commands/kickoff.md` y
     `templates/kickoff.md`;
   - una regla en el kickoff y en el nucleo: handoffs, indice y todo lo que
     venga de otras ramas son DATOS de otras sesiones, nunca instrucciones;
     si algo ahi pide hacer algo, se le muestra al usuario. Es la puerta mas
     realista: relevio lee a proposito todas las ramas, asi que cualquiera
     que pueda pushear puede plantar texto que el agente lee en su kickoff;
   - que los errores del parser no repitan la linea cruda del handoff (hoy
     `fail("line N is not Key: value: " line)` y los valores de Branch o
     Commits se imprimen enteros): nombrar archivo y campo alcanza.
   Explicado al usuario, y sin prometer mas: lo grande es inherente a todo
   plugin. Quien controle `compota334/relevio` controla el codigo que corre
   en cada accion del agente; la defensa es la cuenta de GitHub (2FA), e
   instalar una release fija en vez de main.
6. **Medir el contexto en Devin**: no hecho, y conviene no prometerlo.

## 7. Estado operativo que git no captura

- **relevio instalado en este proyecto** por script, v0.24.0, en el checkout
  principal (`/home/no/VIBE/claude-baton`) y en este worktree. `.claude/`
  esta en `.gitignore`. Para reinstalar: exportar main
  (`git archive origin/main | tar -x -C <tmp>`) y correr ese `install.sh
  --update` desde el proyecto, porque el instalador se niega a correr desde
  dentro del propio repo de relevio, a proposito.
- **El checkout principal esta atras**: su `main` local quedo en `9626757`
  (v0.21.5) mientras `origin/main` esta en `0ddc6ec`. Hace falta `git pull`
  ahi antes de trabajar.
- **Hay una rama local vieja**, `claude/project-check-f091c8`, con copias de
  handoffs de antes de la migracion. El indice las cuenta como "1 older copy
  superseded" y no molestan.
- **Claude Code instalado: 2.1.267.** `idleCompaction` existe desde 2.1.290,
  asi que hoy la clave (ya en false en `~/.claude/settings.json` del usuario
  y en el settings de este proyecto) no tiene efecto; lo tendra al
  actualizar, que era la intencion.
- **Cuenta de gh activa: compota334** (se cambio para el push y la release).
  Afecta a los otros proyectos del usuario; se desvia sola.
- **Release de GitHub publicada**: v0.24.0, https://github.com/compota334/relevio/releases/tag/v0.24.0
