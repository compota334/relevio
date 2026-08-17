Session: 17-08-26 relevio v0.20 anti-anticipacion
Date: 2026-08-17
Dev: NICO
Branch: main (todo pusheado; sin ramas abiertas en relevio)
Commits: bd9f40c..5bd4bb0 (5 commits)
Resume: claude --resume 1255dece-2843-48d3-9f8b-8ed1500fb927
Topics: relevio, anti-anticipacion, prompts, hooks, cadencia, tokens-libres, handoff, arrotrack, code-review, security-review
Summary: Rediseno completo de los mensajes que relevio le inyecta al agente (v0.20.0 y v0.20.1), a partir de dos fallas opuestas observadas en sesiones reales: agentes que cerraban al 40-60% porque conocian los umbrales, y agentes que se creian sin ventana porque el silencio entre reportes era ambiguo. Se elimino relevio.md como archivo de runtime, se agrego la cadencia de checkpoints y los tokens libres, y se porto todo a ARROTRACK (PRs #368 y #377, ambos mergeados) donde ademas quedo un gate de reviews previo a cada PR.

## 1. De que va esto (para quien abra sin contexto)

relevio es la metodologia de sesiones para Claude Code que vive en este repo:
hooks que le informan al agente su uso de ventana y le entregan la metodologia,
mas los comandos /kickoff, /handoff y /revisit. Se distribuye por dos vias,
script installer y plugin de Claude Code, y el repo es a la vez plugin y
marketplace propio. Repo publico en compota334/relevio.

Esta sesion no toco la mecanica del hook (deteccion de modelo, bandas,
marcadores en /tmp): toco **que dice y cuando lo dice**. Es una sesion de
prompts, no de codigo, aunque el resultado sean shell scripts.

## 2. El problema de fondo, que resulto ser DOS problemas opuestos

El sintoma que abrio la sesion: los agentes cerraban sesiones al 40-60% de la
ventana, "yendo cerrando" mucho antes de que el hook lo pidiera. La causa era
que la metodologia les ensenaba las reglas de cierre y los numeros al minuto
cero, asi que anclaban en ellos. Eso se ataco en la v0.20.0.

A mitad de sesion aparecio el sintoma CONTRARIO, y es la parte mas valiosa de
todo lo aprendido. El usuario pego una conversacion real donde un agente decia
"mi recomendacion es cerrar esta sesion", y al preguntarle cuanta ventana habia
gastado respondio que su ultima lectura era 30% y que "habia crecido desde
entonces" sin saber cuanto. O sea: **no se estaba anticipando por saber de mas,
se estaba anticipando por saber de menos**. El silencio entre reportes era
ambiguo y el agente lo rellenaba con ansiedad.

La conclusion, que es la que no hay que re-derivar: **hay dos clases de numeros
y se comportan al reves**.

- Los **umbrales de cierre** (70, 80) son toxicos por adelantado: el agente
  ancla en ellos y empieza a cerrar antes. Siguen sin anunciarse nunca.
- La **cadencia de reportes** (uno cada 10%) es lo contrario: convierte el
  silencio en informacion. Si el ultimo aviso fue 30% y no llego otro, el agente
  SABE que esta entre 30 y 40, y no necesita inventar. Anunciarla calma.

Corolario que se aplico en todos los mensajes: mostrar tambien los **tokens
libres en absoluto**, no solo el porcentaje. "80% usado" se lee como escasez;
"190.000 tokens libres" se lee como lo que es, que alcanza de sobra para
escribir un handoff de dos paginas.

## 3. Que se hizo, con commits

**v0.20.0 (bd9f40c, b231419, 7d02878, e6e9b8e)**

- **bd9f40c**: reescritura completa de los mensajes. El core de inicio de sesion
  paso de ~1800 a ~966 caracteres y dejo de mencionar cierre, handoffs,
  umbrales, guardas y porcentajes. Los checkpoints del 10 al 60% quedaron en UNA
  linea con el numero pelado. El aviso del 70% dejo de frenar y el del 80% paso
  a llevar el checklist completo de cierre, porque es la primera vez que el
  agente lo necesita.
- **b231419**: se elimino `templates/relevio.md`. Era una tercera copia de la
  metodologia que el agente podia leer temprano y aprender el cierre antes de
  tiempo. Todo lo que contenia ya lo entregan los hooks y los comandos. El
  installer ahora lo BORRA al hacer --update, pero solo si la linea de titulo
  prueba que es de relevio (un archivo del usuario con ese nombre sobrevive).
- **7d02878**: /kickoff y /handoff alineados al esquema sin relevio.md; el
  chequeo de version ahora lee el sello de `.claude/hooks/context-warn.sh`.
- **e6e9b8e**: tests y README al dia.

**v0.20.1 (5bd4bb0)**, la parte de esta mitad de sesion:

- Core de inicio: la etiqueta `WORK:` paso a `DURING THE SESSION:` (describe un
  marco, no ordena trabajo), anuncia la cadencia de ~10%, ensena a interpretar
  el silencio, prohibe adivinar el uso, y cierra con la regla de fondo: **la
  ventana nunca decide, decide el pedido del usuario**.
- Todos los mensajes con porcentaje: "of **your** context window", con usados Y
  libres.
- Soft (70%): reencuadre "sweet spot" (maximo entendimiento cargado mas mucha
  ventana libre, la combinacion esta en su pico) en lugar de "todavia tenes
  lugar pero anda cerrando". Se elimino el bullet "avoid STARTING large
  changes": lo decide el usuario, no el hook. Se conservo el cierre "keep
  working".
- Hard (80%): "llevar el trabajo a un punto de corte coherente sin abandonar
  nada a medias" en lugar de "terminá la edicion y commiteala", y **el commit
  paso a DESPUES del handoff**. El orden viejo empujaba a cortar en cualquier
  parte para commitear.
- Tests: dos casos nuevos (tokens libres en el checkpoint, y que el paso 1 del
  hard no pida commit) y ajuste de los que dependian del texto viejo.

## 4. ARROTRACK: dos PRs y un gate de reviews

ARROTRACK tiene su propia adaptacion de relevio a mano en su CLAUDE.md, con
naming de handoff por autor (`YYYY-MM-DD_NOMBRE_handoff.md`) y reglas de casa.
**No usa el installer y no debe usarlo.** Se porta a mano, siempre por rama y
PR.

- **PR #368** (`kickoff-sin-umbrales`, MERGEADO): la causa raiz de que los
  agentes de ARROTRACK siguieran anticipandose aun con el hook v0.20 puesto. El
  comando /kickoff, que corre en TODAS las sesiones, seguia anunciando
  "checkpoints cada 10%, avisos al 70% y 80%": les ensenaba los numeros al
  minuto cero. Ademas la linea 25 del CLAUDE.md invitaba al cierre por cuenta
  propia ("si el contexto se pone corto, la sesion cierra con handoff").
- **PR #377** (`hook-cadencia-y-tokens`, MERGEADO): el port de v0.20.1, con los
  mensajes nuevos adaptados al naming propio y a la regla de regenerar help
  docs. Probado con transcripts sinteticos al 35, 72 y 81%.
- **Gate de reviews previo a PR**: lo pego y commiteo el usuario a mano
  (**e3078ea3**, ya en origin/main). Obliga, antes de CADA Pull Request a main,
  a correr `/simplify`, luego `/code-review`, luego `/security-review`, despues
  los checks del proyecto, y recien ahi commit, push y PR, resumiendo hallazgos
  en el cuerpo del PR. Nacio de un problema concreto: un dev que abre muchas
  sesiones en paralelo y genera codigo de baja calidad.

## 5. Lecciones aprendidas (las que costaron de verdad)

**Negar una idea la instala igual.** Este es el principio que gobierna todo el
diseno. Un checkpoint que dijera "esto NO es senal de cierre" deja la palabra
"cierre" en la memoria de trabajo del agente seis veces por sesion. Por eso los
checkpoints son un numero y nada mas: no una negacion, no un "seguí
tranquilo". La regla operativa quedo escrita en los DESIGN RULE de los dos
scripts: **cada instruccion viaja con el evento que la dispara, nunca antes**.

**El silencio tambien comunica, y si no lo definis, comunica lo peor.** Es la
leccion nueva de esta sesion y la que revirtio un criterio anterior. En v0.19 y
v0.20.0 la regla era "no nombrar ningun numero". Resulto demasiado gruesa: al
sacar TODOS los numeros, el agente perdio la unica herramienta que tenia para
acotar su propio estado, y la ansiedad llena ese vacio. La regla fina es que los
umbrales de cierre anclan y la cadencia desambigua.

**La prueba en vivo, en esta misma sesion.** Despues de un auto-compact, el
usuario me pregunto cuanta ventana habia gastado. Con el mensaje nuevo ya
cargado pude responder exactamente lo que el diseno pretende: "la ultima lectura
fue 10%, no llego otra, asi que por la cadencia se que no cruce la proxima
marca". Sin alarma y sin inventar. El mismo agente, con el mensaje viejo, habia
respondido "he crecido desde entonces pero no se cuanto".

**El sed que corrompe rutas al generar las copias del plugin.** Los hooks del
plugin se generan desde `templates/` transformando los comandos al namespace
(`/kickoff` a `/relevio:kickoff`). Un `sed` global de `/handoff` convierte
tambien `docs/handoff/` en `docs/relevio:handoff/`, que es una ruta inexistente
y silenciosa. **La transformacion correcta protege la ruta con un placeholder
antes de tocar los comandos:**

    sed 's|docs/handoff|__DOCSH__|g; s|/kickoff|/relevio:kickoff|g; s|/handoff|/relevio:handoff|g; s|__DOCSH__|docs/handoff|g'

Vale para cualquier regeneracion futura de `hooks/` desde `templates/`.

**Los tests que grepean digitos se rompen cuando el mensaje incorpora numeros.**
La assertion que verificaba que el checkpoint no nombra los umbrales buscaba
`70|80` a secas. Al agregar el conteo de tokens, un uso de 720.000 contiene "70"
y "80" como substrings y el test habria fallado por una razon falsa. Ahora ancla
con el signo: `70%|80%`. Regla general: en estos tests, anclar el porcentaje al
simbolo, nunca al digito suelto.

**La cuenta de gh volvio a estar cruzada.** Al momento de pushear relevio, la
cuenta activa era AIDeepEconomics aunque el repo es de compota334. Se detecto
con el chequeo de credencial real (no con `gh auth status`, que puede decir una
cosa mientras el helper responde otra) y se corrigio antes del push. Sigue
valiendo como verificacion obligatoria:

    printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep username

## 6. Decisiones tomadas y descartadas, con el razonamiento

Esto es lo que costo derivar y no se deduce leyendo el codigo.

**Por que el gate de reviews vive en el CLAUDE.md de ARROTRACK y NO en
relevio.** El disparador correcto es el Pull Request, no un porcentaje de
ventana. Una feature de ARROTRACK puede vivir varias sesiones en una rama, y el
push de cada cierre existe solo para que el handoff viaje; correr las reviews en
cada cierre revisaria codigo a medio construir (ruido: "esta funcion no se usa",
cuando se iba a usar la sesion siguiente) y pagaria varias veces por el mismo
codigo. Ademas relevio no puede asumir que todo proyecto trabaja con PRs.
Atarlo al hook seria atarlo al reloj equivocado.

**Por que no se puede automatizar con un hook.** Un hook solo puede inyectar
texto en el contexto del agente o bloquear/permitir una accion. **No existe
mecanismo para que escriba en la linea de entrada de la CLI y apriete Enter.**
Los slash commands los interpreta el cliente antes de que el modelo vea nada:
si el agente "tipea" /review en su respuesta, es texto pintado. Lo unico que
podria tipear por el usuario es un proceso externo que maneje la terminal (el
patron de agent operator via tmux/PTY que el README ya documenta), y para esto
seria desproporcionado.

**Pero la instruccion SI alcanza, y esta es la parte util:** `/code-review`,
`/security-review` y `/simplify` son skills invocables por el agente (aparecen
en la lista de skills del harness), no controles de sesion. El agente las corre
por su cuenta cuando una instruccion se lo pide, y cada una lanza **un agente
revisor aparte**: ventana propia, mirada adversarial sin sesgo de autor, y a la
sesion original solo vuelve el reporte de hallazgos, que es chico. Distinto de
`/rename`, que es control de sesion y solo lo puede tipear el humano (por eso
ahi seguimos pidiendole al agente que le pase el comando al usuario).

**`/code-review ultra` esta prohibido en ARROTRACK**: es la variante multiagente
en la nube, se factura aparte y solo la puede lanzar el usuario.

**La GitHub Action de review automatico quedo DESCARTADA.** Era la capa mas
robusta (se ejecuta en cada PR, ningun dev puede saltearla), pero se factura por
tokens de API y la empresa no permite ese gasto. Las reviews corridas dentro de
la sesion de Claude Code, en cambio, consumen la suscripcion del dev. **No
revivir la Action sin que cambie la politica de gasto.** Si algun dia se
retoma, el camino a investigar es `claude setup-token` para CI, verificando
primero los terminos de uso.

**El orden de las reviews no es arbitrario:** `/simplify` primero porque
reestructura y aplica sus propios arreglos (cazar bugs en codigo que esta por
reescribirse es trabajo tirado); `/code-review` segundo, sobre el codigo ya
simplificado, y ademas atrapa lo que simplify pudiera haber roto;
`/security-review` tercero, sobre codigo ya estabilizado; los checks del
proyecto al final, para probar que los arreglos no rompieron nada.

## 7. Pendientes, en orden

1. **Las submissions al directorio de plugins de Anthropic siguen sin
   resolverse** (una del 22/07 con v0.10.0 y otra del 28/07 con v0.18.0). El
   panel de estado esta en https://platform.claude.com/plugins/submissions
   (cuenta compota334 en Console). Lo publicado hoy es v0.20.1, muy superior a
   ambas. Chequeo de aceptacion: buscar "relevio" en
   `anthropics/claude-plugins-community/.claude-plugin/marketplace.json`; el pin
   de commit lo actualiza un bot solo, asi que los pushes nuevos se toman
   automaticamente.
2. **Instalaciones de POLY desactualizadas.** Estado medido al cierre:
   POLY-BIAS-48ELON y POLY-BIAS-TWEET ya estan en v0.20.1; **CAL-TEMP-YES y
   POLY-BOX-MOVIES siguen en v0.15.0**, cinco versiones atras, sin nada del
   trabajo anti-anticipacion. POLY-BOX-MOVIES importa especialmente: su agente
   fue el mejor reportero de bugs que tuvo relevio.
3. **Verificar en uso real que el cambio funciona.** Lo unico que probaria la
   v0.20.1 es una sesion larga de ARROTRACK que llegue al 70-80% sin haberse
   querido cerrar antes. Hasta que eso pase, la mejora es teorica.
4. **El campo `Resume` de los handoffs asume que el `.jsonl` mas reciente del
   proyecto es el de la sesion actual**; con sesiones paralelas puede apuntar a
   la equivocada. Sin resolver desde julio.
5. **Renombrar la carpeta local** `/home/no/VIBE/claude-baton` a `relevio`
   cuando no haya sesiones activas (rompe worktrees abiertos).
6. **Worktree viejo** `.claude/worktrees/project-check-f091c8`, en detached HEAD
   (88dad2d), limpio, de una sesion de julio. Podarlo es seguro; el usuario
   prefirio dejarlo.
7. Del handoff anterior siguen vigentes y deliberadamente cerradas: no revivir
   el auto-update (ejecutaria codigo bajado de internet en cada apertura de
   sesion y tocaria archivos sin permiso), y no agregar un segundo par de
   marcadores para el texto del usuario (afuera del bloque ya es zona intocable
   por construccion).

## 8. Estado operativo que git no captura

- **Cuenta gh activa al cierre: compota334** (la correcta para relevio; para
  ARROTRACK hay que cambiar a AIDeepEconomics). Y ojo con esto, que volvio a
  pasar: durante la sesion la deje explicitamente en AIDeepEconomics despues de
  pushear ARROTRACK, y al momento del cierre estaba de nuevo en compota334 sin
  que nadie la cambiara. **Deriva sola, en ambas direcciones, dentro de la misma
  sesion.** No confiar en la ultima cuenta que uno recuerda haber puesto:
  verificar la credencial real antes de CADA push con el comando de la
  seccion 5.
- **relevio: rama main, todo pusheado, sin ramas abiertas.** La instalacion
  local del propio repo (`.claude/`, gitignoreada) se actualizo a mano a
  v0.20.1 copiando desde `templates/`, porque el installer se niega a correr
  dentro del repo de relevio.
- **ARROTRACK: rama main, con los dos PRs mergeados y el gate de reviews ya en
  origin/main.** Quedan 10 archivos SIN TRACKEAR en su working tree (docs,
  .devin/, material de fuentes) que **no son de esta sesion**: no tocarlos ni
  commitearlos sin preguntar.
- **Ojo con las fechas de git en esta maquina:** el reloj del sistema marca
  2026-08-17 pero los commits de esta sesion quedaron fechados 2026-08-03 y
  2026-08-07. El handoff usa la fecha del sistema. Si `git log` parece
  contradecir este documento, es esto y no un error de registro.
- El conector MCP `aidesigner` pide autorizacion OAuth que una sesion no
  interactiva no puede completar; se habilita desde /mcp en una sesion
  interactiva.

## 9. Foto global

relevio v0.20.1 esta publicado y dogfoodeado, y ARROTRACK quedo alineado con el.
La sesion se puede resumir en una sola idea: **un agente que no puede ver su
propia ventana se comporta segun lo que le contamos de ella, y ese relato es
tan parte del producto como el codigo**. Primero le contabamos de mas (sabia
los umbrales y cerraba antes de tiempo) y despues de menos (no sabia
interpretar el silencio y se creia al borde). La v0.20.1 es el punto medio:
sabe donde esta y cada cuanto se lo van a recordar, no sabe cuando termina, y
tiene explicito que la ventana no manda sobre la tarea.

Lo que queda abierto de verdad son dos cosas que no dependen de escribir codigo:
que Anthropic responda las submissions, y que una sesion larga real confirme en
la practica que los agentes ya no se anticipan. La proxima sesion abre con
/kickoff desde /home/no/VIBE/claude-baton.
