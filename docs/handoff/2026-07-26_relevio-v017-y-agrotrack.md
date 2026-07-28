Session: 26-07-26 relevio v0.17 y agrotrack
Date: 2026-07-26
Dev: NICO
Branch: main (todo pusheado a main; sin ramas abiertas)
Commits: aeb5eee..2bf8667 (10 commits)
Resume: claude --resume 0126210a-186f-44cb-a72c-c6ade4e5c1f3
Topics: relevio, fail-loud, installer, marcadores, versionado, opus-5, cosecha, agrotrack, tests
Summary: De relevio v0.10.0 a v0.17.0 en una sola sesión, empujada casi entera por dos reportes de bugs del agente de POLY-BOX-MOVIES. Lo central: los modelos desconocidos ya no reciben una ventana adivinada, el 70% pasó de freno a cosecha, el installer dejó de tener una trampa de tiempo diferido en sus propios consejos, y ahora hay tests. Además Agrotrack recibió tres PRs (25, 33, 35), todos mergeados.

## 1. De qué va esto (para quien abra sin contexto)

relevio es la metodología de sesiones para Claude Code que vive en este repo:
un hook que le informa al agente su uso de ventana, los comandos /kickoff,
/handoff y /revisit, y una sección de CLAUDE.md con las reglas de trabajo. Se
distribuye por dos vías, script installer y plugin de Claude Code, y el repo es
a la vez plugin y marketplace propio. Repo público en compota334/relevio.

Lo que esta sesión cambió no es cosmético: relevio pasó de "asume cosas
razonables" a "no adivina nunca", y de "avisá que se acaba el contexto" a
"gastá bien lo que queda".

## 2. Qué se hizo, con commits

- **aeb5eee v0.11.0**: un modelo que el hook no reconoce ya NO recibe una
  ventana asumida de 200k. Recibe el conteo crudo cada 100k, sin porcentaje,
  sin aviso de cierre y sin STOP LAW, y el agente decide con lo que sabe de su
  propia ventana. Asumir 200k era un fallback silencioso de manual.
- **683c233**: limpieza de los 4 em dashes del repo.
- **11239fc v0.12.0**: el cierre de sesión entrega `/rename` y `/kickoff` cada
  uno en su propio bloque de código copiable, en vez de embebidos en una frase.
- **9f4f267 v0.12.1**: `claude-opus-5` a la tabla de ventanas (1M, verificado
  contra el catálogo oficial, no inferido del patrón).
- **abaf154 v0.13.0**: el 70% pasa de freno a **cosecha**. Ver sección 4.
- **636076b v0.14.0**: el installer frena si el CLAUDE.md ya trae una
  metodología propia sin marcadores, porque anexar dejaría dos juegos de reglas
  en conflicto.
- **8e858db v0.15.0**: arregla la trampa que introdujo la v0.14.0 (sección 4),
  separa `--update` de `--force`, y estampa la versión en los artefactos.
- **eea8632 v0.15.1**: el installer vuelve a ser idempotente sobre CLAUDE.md
  (agregaba una línea en blanco por corrida, para siempre). Primer test del repo.
- **ee29e33 v0.16.0**: el bloque de CLAUDE.md se reemplaza **en su lugar**, no
  al final, así el texto de abajo no se reordena. Guarda nueva para marcadores
  desbalanceados.
- **2bf8667 v0.17.0**: archivo `VERSION` en la raíz y chequeo en `/kickoff`, que
  compara el sello local contra el publicado y avisa si el repo quedó atrás.

## 3. Archivos clave

`templates/` es la fuente del script installer; `commands/` y `hooks/` son sus
equivalentes del plugin (namespace `/relevio:`, más `session-start.sh` que solo
existe en el plugin). **El hook del plugin debe ser SIEMPRE idéntico a
templates/context-warn.sh: verificar con `cmp` después de cada edición.** La
versión vive ahora en cinco lugares que deben coincidir: `VERSION`, `install.sh`,
los dos JSON del plugin, y los sellos dentro de `templates/context-warn.sh` y
`templates/CLAUDE.md.section`. El installer se niega a instalar si no coinciden.
`tests/install.sh` corre 16 assertions.

## 4. Lecciones aprendidas (las que costaron de verdad)

**La trampa de los marcadores, que planté yo misma.** La v0.14.0 agregó un guard
que, como remedio, le decía al usuario: "envolvé TU metodología en los
marcadores de relevio para protegerla". Pero el bloque entre marcadores es
exactamente lo que `--force` borra. Era una bomba de tiempo: seguías el consejo
para proteger tu texto y lo perdías meses después al actualizar. La raíz es que
el marcador significaba dos cosas opuestas a la vez ("esto lo generó relevio, es
descartable" y "esto es del usuario, respetalo"). Ahora significa solo la
primera, dicho en los cuatro lugares donde el usuario puede leerlo. **Regla que
queda: si está entre los marcadores es de relevio y es reemplazable; si está
afuera es del usuario y es intocable.**

**El contador mintiendo, en vivo y en carne propia.** A mitad de sesión el
usuario cambió a Opus 5 y el hook local (todavía v0.10) no lo reconocía, asumió
200k y disparó "79%, empezá a cerrar" cuando el uso real era 159k de 1M, o sea
16%. El backstop después se autocorrigió, pero el aviso falso ya había salido.
Es exactamente el bug que POLY-BOX-MOVIES reportó, ocurriendo mientras lo
arreglábamos. **El diagnóstico que sirve: un porcentaje imposible o
sospechosamente alto es señal de tabla de modelos vieja, no de sesión larga.**

**Ver un síntoma y descartarlo.** Cuando actualicé el CLAUDE.md de este repo
quedaron dos líneas en blanco antes del marcador. Lo noté y lo llamé "cosmético,
no vale la pena". Era el bug de idempotencia que POLY-BOX-MOVIES reportó una
hora después con evidencia trazada en su historial.

**La cuenta de gh deriva en AMBAS direcciones.** Tres veces en esta sesión, sin
patrón. Y `gh auth status` puede decir una cosa mientras el credential helper
responde otra. **Lo único confiable es
`printf 'protocol=https\nhost=github.com\n\n' | gh auth git-credential get`,
antes de CADA push.** Frenó un push equivocado a Agrotrack.

**Disciplina de tests que quedó establecida:** toda guarda nueva se valida
sacándola a propósito y confirmando que el test falla. Un test que no puede
fallar no vale nada. Se aplicó a las tres guardas nuevas.

## 5. Pendientes, en orden

1. **La submission al directorio de Anthropic sigue sin entrar.** Verificado:
   2269 plugins, cero relevio, cero PRs. **Contexto derivado que importa: el
   proceso es un FORMULARIO (clau.de/plugin-directory-submission), no PRs; los
   PRs contra ese repo se cierran automáticamente.** O sea que "no hay PR" es lo
   esperado, no señal de falla, y NO hay forma pública de confirmar que la
   submission llegó: no hay cola visible ni acuse de recibo. Lo mandó el usuario
   el 22/07 con v0.10.0. Opciones: esperar, o reenviar (costo casi cero, tomaría
   v0.17.0 que está mucho mejor). Antes de reenviar conviene que el usuario
   busque el mail de confirmación del formulario, que sería el único recibo.
2. **Opción (iii) del reporte de POLY-BOX-MOVIES: mover la metodología a un
   `relevio.md` aparte**, dejando en CLAUDE.md solo una referencia. Es
   arquitectónicamente más limpio que los marcadores y haría desaparecer todo el
   problema de "qué parte es de quién" por construcción. **Por qué NO se hizo, y
   esto es lo que no hay que re-derivar: en Claude Code el CLAUDE.md se inyecta
   solo, un `.md` suelto no. Existe el mecanismo de `@import`, pero NO se
   verificó empíricamente en esta sesión, y no se rediseña el formato apoyándose
   en algo no probado.** Si se retoma: verificar primero que un `@relevio.md`
   llegue al contexto con la misma prioridad, y recién ahí planificar migración.
3. **Se descartó a propósito la opción (ii)** (un par de marcadores propios del
   usuario que el installer nunca toque). Razón: con la semántica ya
   desambiguada, "afuera del bloque" YA es la región protegida por construcción
   del awk, y agregar un segundo par sería maquinaria para garantizar algo que
   ya está garantizado. Reconsiderar solo si aparece confusión real en uso.
4. **Se descartó a propósito el auto-update.** Tocaría archivos del repo sin
   permiso, dejaría cambios sin commitear que el usuario no hizo, podría cambiar
   las reglas a mitad de sesión, y significaría ejecutar código bajado de
   internet en cada apertura de sesión. Contradice el diseño entero, que es que
   el installer pregunte antes de tocar nada. No revivir sin una razón nueva.
5. **Repos que ya acumularon líneas en blanco antes del marcador se quedan
   así.** Con el reemplazo en el lugar (v0.16.0) ya no crecen, pero tampoco se
   limpian, porque ahora están fuera del bloque y fuera del bloque no se toca.
   Es deliberado: la promesa vale más que la prolijidad.
6. El campo `Resume` de los handoffs asume el `.jsonl` más reciente del
   proyecto; con sesiones paralelas puede apuntar a la equivocada.
7. SessionStart para el script installer (hoy solo lo tiene el plugin).
8. Renombrar la carpeta local `/home/no/VIBE/claude-baton` a `relevio` cuando no
   haya sesiones activas (rompe worktrees abiertos).
9. Queda el worktree viejo `.claude/worktrees/project-check-f091c8` en detached
   HEAD, limpio, de la sesión anterior. Podarlo es seguro; el usuario prefirió
   dejarlo por ahora.

## 6. Estado de Agrotrack360 (cuenta AIDeepEconomics)

Tres PRs, todos mergeados a main: **#25** (hook v0.11 + cierre con /kickoff en
bloque), **#33** (opus-5 + cosecha + razonamiento en el handoff) y **#35** (sello
de versión + que /kickoff lo reporte). Sin ramas abiertas.

**Lo que hay que recordar antes de tocarlo: Agrotrack NO usa el installer y no
debe usarlo.** Su CLAUDE.md tiene la metodología integrada A MANO, en español, y
conserva a propósito su esquema de nombres con autor
(`YYYY-MM-DD_NOMBRE_handoff.md`) más sus reglas de UI y de PRs. Las mejoras de
relevio se portan a mano, adaptándolas. Eso quedó escrito dentro de su propio
CLAUDE.md en el #35, así que ya no depende de que alguien se acuerde. El guard
de la v0.14.0 además lo protege: correr install.sh ahí ahora frena en vez de
anexar una segunda metodología.

## 7. Estado operativo que git no captura

- **Cuenta gh activa al cierre: AIDeepEconomics.** Para pushear relevio hay que
  cambiar a compota334 primero, y verificar la credencial real (ver sección 4).
- El agente de **POLY-BOX-MOVIES** es un reportero de bugs activo y bueno: dos
  reportes esta sesión, ambos válidos y ambos reproducidos. Vale la pena tomarlo
  en serio cuando escriba. Está actualizando de v0.10.0; conviene que vaya
  directo a v0.17.0.
- Este repo no puede correr su propio install.sh (el installer lo prohíbe), así
  que su instalación local se actualiza a mano. Se hizo al cierre: local en
  v0.17.0, alineado con lo publicado.
- `.claude/` y `CLAUDE.md` de este repo están gitignoreados (config local por
  dev); `docs/handoff/` sí se commitea.

## 8. Foto global

relevio v0.17.0 está publicado, testeado y dogfoodeado. La sesión tuvo una forma
poco común y vale la pena nombrarla: casi todo el trabajo salió de reportes de
un agente que usa relevio en otro proyecto, y dos de los bugs más serios los
había introducido yo pocas horas antes. El repo terminó con lo que no tenía al
empezar: tests, versionado visible, un installer que no puede mentir sobre lo que
toca, y un hook que prefiere no decir nada antes que decir un número inventado.
Lo único abierto de verdad es la aprobación de Anthropic, que no depende de
nosotros. La próxima sesión abre con /kickoff desde /home/no/VIBE/claude-baton.

---

## Addendum (2026-07-28, sesion v0.18)

El pendiente 1 (submission a Anthropic) quedo RESUELTO en su parte incierta:
existe un panel de estado en https://platform.claude.com/plugins/submissions
(cuenta compota334 en Console). Ahi se ve que la submission del 22/07 SI llego
y sigue "Submitted and pending review". El 28/07 el usuario envio una segunda
submission con la descripcion de v0.18.0 y tres use cases; ambas apuntan al
mismo repo. Chequeo de aceptacion: buscar "relevio" en
anthropics/claude-plugins-community/.claude-plugin/marketplace.json (el
catalogo sincroniza de noche tras la aprobacion; el pin de commit lo actualiza
un bot solo, asi que los pushes nuevos se toman automaticamente).
