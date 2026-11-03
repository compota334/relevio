Session: 03-11-26 relevio v0.24.6 y blueprint del archivo de sesiones
Date: 2026-11-03
Dev: NICO
Branch: main
Commits: 7a29b5b..3aa3562
Areas: .claude-plugin, README.md, VERSION, commands, hooks, install.sh, scripts, templates, tests, uninstall.sh
Resume: claude --resume e6bbe7e5-445b-4b79-8c6a-59eeffa68047
Topics: relevio, seguridad, inyeccion-de-prompt, cabecera-calculada, needs-fixing, reinicio-vs-archivo, worktrees, release, investigacion, archivo-de-sesiones, blueprint
Summary: De v0.24.0 a v0.24.6 publicadas (seguridad contra texto de otras ramas, cabecera de handoff calculada, Opcion B, reinicio que no se confunde con archivo) y blueprint aprobado del archivo encriptado de sesiones para v0.25.0, que la proxima sesion empieza a codear

## 1. Contexto general

relevio es la metodologia de sesiones para agentes de IA que vive en este repo
(`compota334/relevio`, publico). Esta sesion fue larga y tuvo dos mitades:

1. **Codigo (15-16 de octubre):** de v0.24.0 a v0.24.6, todo publicado en
   `main` y con releases en GitHub. Seguridad frente a texto escrito por otros,
   la cabecera del handoff calculada por relevio, la Opcion B (el handoff roto
   de otro dev ya no traba el indice), y el arreglo del mensaje de "archivo"
   que frenaba a agentes vivos despues de un reinicio de la PC.
2. **Investigacion y planificacion (2-3 de noviembre, sin codigo):** como
   guardar las conversaciones de Claude Code para que no se pierdan. Tres
   deep research y un blueprint completo del "archivo encriptado de
   sesiones", que es la v0.25.0. **La proxima sesion empieza a codearlo.**

## 2. Lo que se hizo (codigo), version por version

Rango: `git log 7a29b5b^..3aa3562`. Todo en `main`, pusheado. Releases en
GitHub: v0.24.5 y v0.24.6. Las notas de v0.24.0 tambien se corrigieron.

| Commit | Que trajo |
|---|---|
| `7a29b5b` v0.24.1 | Parser: nombres de handoff solo `[A-Za-z0-9._-]` despues de la fecha; rechaza caracteres invisibles, bidi, tags Unicode y de control en TODO el handoff (cabecera y cuerpo; ZWJ y ZWNJ permitidos por los emojis); los errores nombran archivo, linea y campo, nunca el valor. Kickoff: el nombre de archivo va entre comillas simples, la consulta de VERSION pasa por `grep -E '^[0-9]+\.[0-9]+\.[0-9]+$'`, mapa de worktrees, regla de "lo sospechoso se consulta". `/revisit` arma el comando solo con el id. `CLAUDE_CONTEXT_LIMIT` validado como numero (antes, `a[$(cmd)]` ejecutaba codigo dentro de `$(( ))`, reproducido). Marcadores del hook a una carpeta privada. |
| `fa3f8d9` | Cabecera calculada: el hook de arranque le dice al agente su SESSION ID y anota hora y commit de inicio en `<git-common-dir>/relevio/sessions/<id>`; `scripts/relevio-header.sh` imprime Date, Dev (`git config relevio.dev`), Branch, Commits, Areas, Resume; el agente completa Session, Topics y Summary; el indice rechaza un `<fill in` sin completar. |
| `f8bc4e0`, `e3aa99d` | Opcion B: un handoff roto que solo existe en la rama de otro dev queda fuera del catalogo y se lista en "Needs fixing"; en tu working tree, tu rama o main sigue frenando. Tambien se arreglo `contains()` de los tests (ver lecciones). |
| `98ce533` | Version y README de la cabecera calculada; mensajes del 80% y 85% piden la cabecera al script. |
| `0739e9f` | Los 8 hallazgos de `/code-review`: el header deja fuera merges y calcula Areas solo con commits propios; filtra por fecha sin `--since` de git; un commit de inicio inexistente frena; campo desconocido nombrado por linea; marcadores a `~/.cache/relevio/markers`; limpieza de registros de mas de 30 dias; LC_ALL=C en el chequeo del id; `/handoff` pide texto plano. |
| `5342a57` | Renombrar 0.25.0 a 0.24.5 (decision del usuario). Publicada como release v0.24.5. |
| `3aa3562` v0.24.6 | Un handoff que nombra la sesion es indicio, no prueba de archivo: el mensaje de "REOPENED" nombra el handoff encontrado y el agente decide comparando con su propia conversacion. Release v0.24.6. |

Suite: `bash tests/install.sh`, en verde al cierre de la parte de codigo. No
hay type-checker ni linter (bash y markdown; `shellcheck` no esta instalado).

## 3. Investigacion (sin codigo)

Tres reportes de deep research, en el **Escritorio del usuario** (no en el
repo):
- `~/Desktop/Preserving Claude Code Session Transcripts for relevio_ Encrypted Backup Research Report.md`:
  diseno tecnico del backup (age, restic, riesgos, restauracion).
- `~/Desktop/Encrypted Storage and Sharing of AI Coding-Agent Conversations_ Market Assessment of relevio Cloud (November 2026).md`:
  negocio. Veredicto: nicho, no una empresa grande. Anthropic, OpenAI y GitHub
  ya entregan transcripts a clientes Enterprise; Entire (60 M USD) y SpecStory
  apuntan a compartir. El hueco: equipos chicos, varios agentes, encriptado de
  punta a punta, en el almacenamiento propio del cliente ("vender candados y
  llaves, no alquilar depositos"). Plan: gratis primero; cobrar solo si unas
  300 personas de afuera lo usan cada semana.
- `~/Desktop/Searching a Private Archive of Claude Code Conversations_ Agentic Search First, Local Hybrid Retrieval Second.md`:
  RAG. Veredicto: primero busqueda por handoffs mas grep, despues SQLite FTS5,
  y embeddings locales solo si una prueba con preguntas propias lo justifica.
  El indice es tan sensible como el texto. **El RAG queda pendiente.**

Datos medidos en esta PC que importan para lo que sigue:
- unas 970 conversaciones, 3,4 GB, 110 carpetas en `~/.claude/projects`;
- 54 carpetas son de worktrees;
- gzip comprime 4 veces;
- solo el 1,9% de los bytes es conversacion; el resto son salidas de
  herramientas;
- Claude Code 2.1.303; `age` no instalado (apt ofrece 1.1.1).

## 4. Lo que sigue: el archivo encriptado de sesiones (v0.25.0)

**La especificacion completa esta en un blueprint local, NO commiteado:**

    /home/no/VIBE/claude-baton/docs/blueprints/2026-11-03_session-archive.md

`docs/blueprints/` esta excluido por `.git/info/exclude`, asi que el archivo
existe SOLO en el checkout principal. Si la proxima sesion corre en un
worktree, tiene que leerlo por esa ruta absoluta. Tiene 951 lineas con:
- decisiones (con la pregunta y la respuesta);
- datos medidos;
- formatos exactos y comandos de age;
- algoritmos de archivado y restauracion;
- mensajes al agente;
- 9 fases de 5 archivos o menos;
- 8 experimentos previos y mas de 60 casos de test;
- la checklist manual para el usuario;
- el modelo de seguridad.

Leerlo entero antes de escribir codigo. Las secciones 1 a 3 no se discuten de
nuevo.

En una linea: un hook SessionEnd nuevo y un barrido al arrancar archivan cada
sesion en segundo plano, comprimida y encriptada con `age` para dos
destinatarios:
- una clave principal, protegida por contrasena;
- una clave de recuperacion, que el usuario guarda.

Se guarda en `~/.relevio/archive/`, fuera de todo repo, y se restaura con un
comando que se corre en la terminal del usuario.

Decisiones del usuario que estan en el blueprint (seccion 2), resumidas:
- automatico en proyectos con relevio, mas un backfill unico de toda la PC;
- rama nueva y merge al final;
- `~/.relevio/archive/`;
- contrasena mas clave de recuperacion;
- respetar los borrados de la app de escritorio ("Respetar y avisar");
- version v0.25.0;
- subir `cleanupPeriodDays` a 3650 SIEMPRE, en los dos canales, con aviso. El
  usuario rechazo la recomendacion de hacerlo solo despues del setup.

## 5. Pendiente, por prioridad

1. **Arreglar el registro de inicio de sesion (defecto real, encontrado al
   escribir este handoff).** `record_session_start()` en
   `hooks/session-start.sh` escribe la hora de AHORA la primera vez que ve un
   id. Esta sesion empezo antes de que existiera esa funcion, asi que el
   registro se creo al reanudarla (16-10 03:22, apuntando a `5342a57`), no
   al empezar (15-10 17:54).
   - **Efecto:** `relevio-header.sh` sin `--since` habria omitido en silencio
     los commits `7a29b5b..0739e9f`.
   - **La salida que da el script hoy tambien falla:** "pregunta al usuario
     cuando empezo y usa `--since`" es fragil. Con `--since "2026-10-15
     00:00"`, el rango incluyo `e59a5fd`, que es de la sesion ANTERIOR del
     mismo dia.
   - **Arreglo propuesto:** usar como hora de inicio el primer `"timestamp"`
     del transcript (el payload trae `transcript_path`), no la hora actual.
     Para una sesion que ya existe, tomar como commit de inicio el ultimo
     commit anterior a ese timestamp, y no HEAD.
   - Va como primera fase del trabajo de v0.25.0, en la misma rama. Este
     handoff uso `--since 2026-10-15T17:54:23Z`, tomado del primer mensaje del
     transcript.
2. **Fase 0 del blueprint.**
   - El usuario instala age con `sudo apt install age`. Necesita sudo:
     relevio nunca lo instala solo.
   - Correr los experimentos E1 a E8 y anotar los resultados en la tabla de la
     seccion 16 del blueprint.
   - Crear la rama `session-archive` desde `origin/main`.
3. **Fases 1a a 7 del blueprint**, cada una con `bash tests/install.sh` en
   verde antes de seguir.
   - En la fase 6 (subir la version) pedirle al usuario la excepcion a la
     regla de 5 archivos: son 10 y es mecanico.
   - Antes del merge: `/simplify`, `/code-review` y `/security-review`.
4. **Modo Devin (foreign host):** el mensaje `off_notice` de
   `hooks/context-warn.sh` todavia le dice al agente "use that knowledge to
   decide when to wrap up the session with a handoff". El usuario lo pospuso:
   relevio no dice que funcione en Devin.
5. **RAG sobre las conversaciones:** pendiente por decision del usuario. El
   diseno recomendado esta en el tercer reporte del Escritorio.
6. **Medir el negocio:** solo despues de que el archivo exista y lo use gente
   de afuera (criterios del segundo reporte).

## 6. Decisiones de diseno y su porque (lo que no se re-deriva gratis)

- **Lo sospechoso se consulta, lo normal se sigue.** El usuario rechazo
  "todo lo de otras ramas es solo datos", porque romperia la funcion del
  handoff (dejar escritos los pendientes). Por eso la regla del nucleo y del
  kickoff enumera que cuenta como sospechoso.
- **El campo `Resume:` no se valida en el parser.** En los repos reales tiene
  decenas de formas de texto libre (`sesion de ZCode sess_...`, `unknown`,
  parrafos). Validarlo habria trabado el tablero de casi todos. El arreglo va
  donde se USA: `/revisit` extrae solo el id con un patron estricto.
- **Los ids de ZCode** tienen la forma `sess_<uuid con guiones>`, a veces con
  `_` extra (medido en `~/.zcode/cli/db/db.sqlite`). Patron:
  `^sess_[A-Za-z0-9_-]+$`.
- **Opcion B:** "propio" significa: en el working tree, en la rama actual
  (por nombre) o en main. Ademas se comparan blobs en `HEAD:<path>` y
  `MAIN:<path>`, porque el escaneo guarda UNA rama por contenido distinto, y
  la misma copia rota puede estar tambien en tu rama con otro nombre.
- **Un handoff que nombra la sesion no prueba que este archivada.** Hay ids
  repetidos en dos handoffs en ARROTRACK y poly-messages: handoffs a mitad de
  sesion, o ids equivocados del metodo viejo. Equivocarse hacia "reinicio" es
  lo barato, porque los avisos de contexto igual protegen una ventana llena.
- **Version 0.24.5 y no 0.25.0** para la cabecera calculada: decision del
  usuario. Los mensajes de los commits `98ce533` y `0739e9f` dicen 0.25.0
  porque se escribieron antes del cambio; no se reescribio el historial.

## 7. Lecciones (problemas que costaron varios intentos)

1. **`printf | grep -q` bajo `pipefail` falla al azar.** `grep -q` corta en
   la primera coincidencia, el que escribe recibe SIGPIPE, y la tuberia da
   error aunque el texto SI coincida. Aparecio dos veces en los tests, con
   textos largos (kickoff.md crecio). Arreglo: `contains()` usa un
   here-string (`grep -q -- "$2" <<<"$1"`), y todas las comprobaciones sueltas
   pasaron a `contains()`. Es la misma familia que la leccion 1 del handoff
   anterior.
2. **Un apostrofo dentro de `${VAR:+ ... }` entre comillas dobles rompe el
   parseo de bash** ("unexpected EOF"). Se reescribio la frase sin apostrofo.
3. **Comillas dobles dentro de un `emit "..."`** cierran el mensaje y
   rompieron 8 tests de una vez. Escaparlas siempre (`\"SESSION ID\"`).
4. **Un commit salio con un test en rojo** (`f8bc4e0`), porque se encadeno con
   `;` en vez de cortar ante el fallo. Desde entonces:
   `bash tests/install.sh >/dev/null 2>&1 && git add -A && git commit ...`.
5. **Un test que pasa contra el codigo viejo no prueba nada.** Cada test
   nuevo se corrio contra la version anterior en una copia en el scratchpad.
   Asi aparecio que el de "valor plantado no se repite" no llegaba al chequeo
   que decia probar.
6. **La cuenta de gh se desvio otra vez**, entre push y push, de compota334
   a AIDeepEconomics. Se verifico con `git credential fill` antes de cada
   push. La memoria del agente ya lo registra.
7. **El registro de inicio no sirve para sesiones anteriores a la funcion**
   (pendiente 1). Lo detecto la propia cabecera de este handoff.

## 8. Estado operativo que git no captura

- **relevio instalado por script en este proyecto en v0.24.6** (carpeta
  `.claude/`, ignorada por git). Para reinstalar: `git archive HEAD | tar -x -C
  <tmp>` y despues `bash <tmp>/install.sh --update` desde la raiz. El
  instalador se niega a correr desde el propio repo.
- **`git config relevio.dev NICO`** quedo grabado en este clon.
- **Cuenta activa de gh: compota334.** Hay que cambiarla para los proyectos
  de AIDeepEconomics. Se desvia sola.
- **Claude Code 2.1.303:** `idleCompaction: false` ya tiene efecto.
  `cleanupPeriodDays` todavia NO esta subido en `~/.claude/settings.json`
  (vale el default de 30). Lo va a hacer v0.25.0. Mientras tanto, las
  sesiones de terminal de mas de 30 dias se siguen borrando.
- **El blueprint y los reportes no estan en git:** el blueprint en
  `docs/blueprints/` (excluido) y los reportes en el Escritorio.
- **`docs/blueprints/`** ya existia vacia, creada por otra sesion el 2-11.
- No hay servicios ni procesos corriendo.
