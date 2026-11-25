Session: 25-11-26 relevio v0.25.0 copia fuera de la PC, sellos y setup guiado
Date: 2026-11-25
Dev: NICO
Branch: session-archive
Commits: 0cba56f..241a152
Areas: README.md, commands, docs, hooks, install.sh, scripts, templates, tests, uninstall.sh
Resume: claude --resume 2c0d64cb-aab8-41c4-b8b3-c322c65487c9
Topics: relevio, archivo-encriptado, copia-fuera-de-la-pc, rclone, google-drive, s3, backblaze-b2, opentimestamps, sello-de-llaves, pull, rotate-recovery, setup-guiado, seguridad, usabilidad
Summary: v0.25.0 completa en session-archive y pusheada (copia encriptada fuera de la PC por carpeta o rclone, remote connect, pull, rotate-recovery, sellos OpenTimestamps, sello de la lista de llaves, setup guiado con colores), con las tres revisiones hechas dos veces; falta la prueba real con Backblaze B2 y abrir el PR

# relevio v0.25.0: copia fuera de la PC, sellos de tiempo y setup guiado

## 1. Contexto general

relevio es la metodologia de sesiones de este repo (`compota334/relevio`,
publico). La sesion anterior (handoff `2026-11-21_relevio-v0247-y-archivo-encriptado-v0250.md`)
dejo el archivo encriptado local (v0.25.0) terminado en la rama
`session-archive`, sin merge. Esta sesion (24 y 25 de noviembre, con un
reinicio de la PC en el medio) empezo con /kickoff y la prueba de restore, y
despues NICO decidio que v0.25.0 sale "bien hecha, nada a medias": todo lo
que sale de la PC encriptado, copia en la nube, rotacion de la clave de
recuperacion y sellos de tiempo, todo en la misma version.

La ultima hora fue en modo autonomo (NICO se fue un par de horas): reglas
en la seccion 7.

## 2. Lo que se hizo, en orden (21 commits, todos pusheados como compota334)

### 2.1 Prueba de restore real (sin commit)
La conversacion descartable `715836ee` se aparto con mv, NICO corrio restore,
keys check y keys check --recovery en su terminal: todo ok, hash identico.

### 2.2 Las dos llaves y la guia (`0cba56f`)
NICO se confundio: dejo vacia la contrasena en el setup original, age invento
una frase con guiones y parecia una frase de recuperacion. Cada pantalla
ahora nombra PASSPHRASE (everyday key) y RECOVERY KEY (emergency key), dice
como se ve cada una y como pegar en Linux/macOS/Windows. Comando nuevo
`guide`: instrucciones para el agente.

### 2.3 Copia fuera de la PC (`729b8b6`, `5e6439c`, `bac9727`)
- `scripts/relevio-archive-remote.sh` (modulo nuevo, sourced): `remote set
  folder|rclone`, `push`, `verify`, `pull`, `remote status|off`.
- Layout de la copia: `README.txt`, `machines/<id>/b/<opaco>.age`,
  `machines/<id>/keys/{main.age,recipients.txt,recipients.mac}`,
  `machines/<id>/catalog.age` (indice, carpetas, olvidados, registros de
  subida, sellos: todo encriptado; escrito al final).
- Nombre opaco = sha256(copy_salt/carpeta/bundle), 32 hex.
- push: modo `audit` (lista lo que la copia tiene de verdad, una llamada) o
  `records` (confia en `remote.tsv`); despues de cada sesion audita una vez
  por dia, `push` siempre. Solo `forget` borra de la copia.
- verify: md5 del proveedor de TODOS los bundles, muestra por sha256, y
  catalogo comparado con el que esta PC escribio.
- pull: home vacio, retoma si se corta, valida todo (ver 2.6).
- `keys rotate-recovery`: hueco encontrado (la clave de recuperacion no se
  podia cambiar); reencripta todo y reemplaza la copia.

### 2.4 Sellos de tiempo (`dea99cf`)
- `scripts/relevio-archive-stamps.sh` y `scripts/relevio-ots-helper.py`.
- Hoja por generacion: texto `relevio timestamp leaf 1` + `salted-sha256
  <sha256(sal + "\n" + transcript)>`; sal aleatoria de 32 bytes.
- Lotes: hoja mas vieja de 24 h, 10 000 hojas, o `stamp now`; el cliente
  `ots` arma el arbol de Merkle solo (medido: 2000 hojas, una llamada, 3,7 s).
- `proof <id>` arma la carpeta para otra persona; `proof-check` verifica con
  dos exploradores (blockstream.info, mempool.space): uno que coincida
  alcanza, uno que no coincida invalida.
- Cliente en venv propio `~/.relevio/ots-venv`, `opentimestamps-client==0.8.0`.
- NICO eligio: los cuatro usos (auditoria, propiedad intelectual, disputas,
  equipos); RFC 3161 NO en esta version ("solo open timestamps luego le
  agregamos otro").

### 2.5 Primera ronda de revisiones (`0daab8e`, `dff5751`, `9340ebe`)
- /simplify: menos trabajo por sync (no tocar la copia sin nada nuevo, un
  solo find), helpers compartidos (tools_load, kv_status_write, run_isolated,
  lock_or_die, archive_stats, safe_msg).
- /code-review: el sello se identificaba por nombre de bundle y se rompia
  cuando Claude reescribe una sesion (reproducido); ahora por contenido
  (carpeta/sesion/sha). pull toma el lock. status no se corta. Auditoria de
  carpeta por tamano. Destino con salto de linea rechazado.
- /security-review (3 vulnerabilidades confirmadas, 8/10): age no firma, asi
  que quien escribe en la copia puede armar un catalogo que la llave abre.
  1) `seq a[$(cmd)]` en el catalogo ejecutaba codigo en `$(( ))`; 2) un
  `recipients.txt` con una llave de mas hacia legible todo lo futuro; 3) un
  symlink en el catalogo exfiltraba llaves SSH o el token de rclone. Arreglo:
  validacion campo por campo (`tsv_valid`), rechazo de links, y el SELLO de
  la lista de llaves (`keys/recipients.mac`: sha256(sha256(secreto) "\n"
  sha256(recipients.txt)), una linea por llave).

### 2.6 Usabilidad pedida por NICO (`b9203e5`..`d5fbe62`)
- Setup: dice que pego el usuario si no coincide; avisa que age borra su
  pregunta; dice que relevio CREA la clave de recuperacion (NICO creia que
  la tenia que crear el).
- `SELF_CMD`: los comandos sugeridos incluyen RELEVIO_HOME y
  CLAUDE_CONFIG_DIR cuando no son los de siempre (antes apuntaban al archivo
  real durante la prueba).
- Pantallas con colores, recuadros e iconos (solo en terminal real), y el
  backfill corre solo al final del setup.
- `remote connect b2 <bucket> | s3 <bucket> <endpoint> <provider> | gdrive`:
  pide solo la llave (oculta), la prueba en una config de rclone aparte y la
  suma a la real solo si funciona, fija la copia y manda todo.
- README: S3 compatible como camino para equipos.

### 2.7 Modo autonomo (`a4dff8b`..`241a152`)
- Menos llamadas por push (medido con un contador: 10 a 6 en el primer push,
  1 sin nada nuevo con auditoria, 0 en una corrida sin nada nuevo).
- Aviso de compactacion acortado: peor caso 5989 a 5949 de 6000.
- `relevio-header.sh` con `--first-parent`: no cuenta commits que llegan por
  merge (el defecto del handoff anterior, seccion 0).
- Segunda ronda de las tres revisiones sobre lo nuevo: readers unificados,
  install_key_list, indice validado al cargar; pull de copia sin sello con
  `--accept-unsealed` que exige LAS DOS llaves y que la lista sea exactamente
  sus dos publicas (hallazgo de seguridad: con una sola llave, el atacante
  podia cambiar la otra).

Suite: `bash tests/install.sh`, 657 casos en verde, 0 salteados. Cada guarda
nueva se rompio a proposito y su test dio rojo; se restauro con cp.

## 3. Decisiones de NICO (pregunta y respuesta)

- "Para que v0.25.0 salga completa, que entra?" -> "Todo, con OpenTimestamps".
- Indice local: "Encriptado al salir" (en la PC queda en claro).
- Transporte: "Los dos caminos" (carpeta y rclone). Nube de prueba: "Google
  Drive con rclone"; luego, con el limite de Google: "Reintentar mas tarde";
  despues de la explicacion de alternativas: "S3 ahora, Drive nativo luego".
- Prueba solo con una conversacion: "no quiero subir mis conversaciones a
  google drive, probemoslo solo con una conversacion".
- Usabilidad, textual: "la mayoria de estas cosas las deberia hacer el propio
  agente de IA, no el usuario. El usuario deberia solo poner la password y
  poco mas", "deberia ser un script que hace todo o que claude los haga",
  "si claude necesita informacion del usuario puede pedirselo en un
  formulario", y terminal "con colores, dibujos y cosas".
- Diseno: "tener siempre como 2 cosas para todo si la 1 no es como esperamos
  tenemos la 2 (esto no significa un fallback de peor calidad)". Guardado
  como memoria `plan-b-design`.
- Modo autonomo: "Solo el PR" (sin tags ni releases), aviso "Si, acortala",
  prueba B2 "Si, al volver".

## 4. Pendiente, por prioridad

1. **Prueba real con Backblaze B2** (NICO, al volver). NICO tiene que crear
   la cuenta (10 GB gratis, sin tarjeta), un bucket privado y una llave de
   aplicacion limitada a ese bucket (Read and Write). Despues el agente:
   `bash <scratchpad>/drive-test/pc1.sh remote connect b2 <bucket>` en una
   pestana de terminal que abre el agente; NICO pega keyID y applicationKey.
   Luego verify, pull a pc2.sh (pide la contrasena de prueba y, si se usa
   --recovery, la clave de prueba), restore y comparar con
   `drive-test/original.sha256`. Despues stamp setup, stamp now, y horas
   despues proof y proof-check. Ver seccion 6 para la carpeta de prueba.
2. **Abrir el PR** de `session-archive` a main (34 commits sobre main). NICO
   pidio un solo PR grande al final. Choque con la regla 29 de su CLAUDE.md
   (PR solo cuando la rama anda de punta a punta y despues de su prueba
   manual): propuesta, PR en borrador hasta la prueba B2. Ver seccion 7.
3. **Release v0.24.8** (tag y release que la sesion de v0.24.8 no hizo) y
   despues release v0.25.0: decision y accion de NICO.
4. **Drive nativo** ("Conectar Google Drive" con una app de relevio
   registrada en Google, permiso drive.file, no sensible: verificacion
   basica, sin auditoria de seguridad). Requiere que NICO registre la app en
   Google Cloud (cuenta, pantalla de consentimiento, politica de
   privacidad). Proxima version.
5. **Equipos**: invitar, sacar (obliga a recifrar) y compartir de a una
   conversacion con revision de secretos. El formato ya cifra a N llaves.
6. Test del camino exitoso de `remote connect` (hoy solo fallas): necesita
   un rclone falso en PATH o un proveedor real.
7. RFC 3161 como segundo sello (despues). Seleccion de un solo mensaje en
   las pruebas (despues).
8. Siguen de antes: avisos de context-warn a 90/95/99% que hablan de
   auto-compact, la capa `~/.claude.json`, un "doctor" de compactacion, E5
   (SessionEnd en la app de escritorio), off_notice para Devin, RAG, medir
   el negocio, ramas locales viejas (`retention`, `disable-all-compaction`,
   `claude/project-check-f091c8`) que borra NICO si quiere.
9. Defecto de relevio visto en el kickoff: el tablero mostro
   `disable-all-compaction` como "4 ahead of main" aunque su PR #1 se mergeo
   con commits nuevos (GitHub los copio con otro hash). El indice compara
   hashes, no contenido; arreglo probable: comparar `git cherry` o el
   patch-id.

## 5. Decisiones de diseno y su porque

- **age no firma.** Es la raiz de todo lo de seguridad: cualquiera con las
  llaves publicas (que viajan a la copia) arma archivos que la llave del
  dueno abre. Por eso: todo lo que vuelve de la copia se valida campo por
  campo, se rechazan links, y la lista de llaves se SELLA con cada secreto.
  Un catalogo falso igual puede plantar una conversacion falsa (README lo
  dice): la defensa es que no ejecuta nada ni lee nada local.
- **El sello solo se escribe donde el usuario tipea una llave** (setup,
  reset, rotate, keys check, pull). push no tiene secreto: no puede sellar,
  por eso push marca la copia como no ok si falta el sello.
- **Indice en claro en la PC, encriptado al salir**: en la PC no revela nada
  que `~/.claude/projects` no muestre ya en claro.
- **S3 para equipos** y no Google Drive: la app compartida de rclone en
  Google tiene un limite global de peticiones (medido 2026-11-25: la subida
  quedo trabada casi una hora). S3/B2/R2 no tienen ese limite y una llave
  limitada a un bucket es el menor privilegio.
- **Con rclone, una sola llamada por archivo** (sin .part y rename): un
  object store solo muestra el objeto cuando termino la subida (medido en
  Drive). La carpeta sigue con .part y rename.
- **Sellos por contenido, no por nombre de bundle**: supersede renombra el
  bundle viejo y reusa `<id>.tgz.age` para contenido nuevo.
- **`--first-parent` en la cabecera** en vez de excluir main: no hay que
  adivinar cual es la rama de integracion. Costo aceptado: un merge de otra
  rama tuya a esta tampoco cuenta.
- **SETUP_BACKFILL** es una perilla de test (en el bloque unico de perillas):
  los tests arman archivos con conversaciones en casi todas sus carpetas y
  el backfill automatico del setup les cambiaria el estado.

## 6. Estado operativo que git no captura

- **Rama `session-archive` pusheada** en `241a152` (origin al dia). El PR no
  esta abierto todavia.
- **Cuenta gh activa: AIDeepEconomics** (se desvio sola otra vez). Los push
  se hicieron como compota334 con
  `git -c credential.helper= -c 'credential.helper=!f(){ echo username=compota334; echo "password=$(gh auth token --user compota334)"; }; f' push origin session-archive`,
  sin cambiar la cuenta global.
- **Archivo real `~/.relevio`**: 1398+ conversaciones, ahora con la lista de
  llaves SELLADA con las dos llaves (NICO corrio keys check y keys check
  --recovery el 25-11). No tiene copia fuera de la PC configurada.
- **rclone 1.60.1** instalado (apt), remote `relevio-gdrive` con
  `scope=drive.file` en `~/.config/rclone/rclone.conf` (600).
- **Google Drive de NICO**: carpeta `relevio-test` con UN bundle de la
  conversacion descartable (experimento R2) y carpeta `relevio-test2` con la
  copia de prueba (1 bundle, llaves, sello, catalogo, README, y dos restos
  `recipients.txt.part` y quizas `main.age.part` de antes del arreglo de
  llamadas). Borrar ambas carpetas al final de la prueba (van a la papelera).
- **Carpeta de prueba** en el scratchpad de esta sesion:
  `/tmp/claude-1000/-home-no-VIBE-claude-baton/2c0d64cb-aab8-41c4-b8b3-c322c65487c9/scratchpad/drive-test/`
  con `pc1.sh` (archivo de prueba con UNA conversacion, ya configurado con
  contrasena de prueba de NICO y copia en relevio-gdrive:relevio-test2),
  `pc2.sh` (la "PC nueva", vacia) y `original.sha256`. Esta en /tmp: un
  reinicio la puede borrar; si pasa, se rearma copiando la conversacion
  `715836ee` del archivo real a una carpeta nueva.
- **Pruebas de OpenTimestamps** del experimento en `scratchpad/ots/` (venv y
  `work/leaf.bin.ots` ya confirmado en el bloque 977416).
- **Blueprints locales** (no van a git, excluidos):
  `docs/blueprints/2026-11-24_v0250-complete-release.md` (con los resultados
  de los experimentos R1, R2, O1, O3, O4) y
  `docs/blueprints/2026-11-24_opentimestamps.md`.
- **Cron de esta sesion** (despertador cada 15 minutos del modo autonomo):
  se borra al cerrar; muere solo con la sesion.
- **relevio instalado en este proyecto** a mano en `.claude/` (ignorada por
  git), con los scripts de esta rama.

## 7. Lecciones

1. **No editar un script mientras el usuario lo esta corriendo**: bash lee el
   archivo de a pedazos y el setup de NICO termino con un `syntax error` falso.
2. **R_ERR se pierde dentro de `$( )`** (subshell): los transportes que
   devuelven datos escriben en un archivo de salida.
3. **Variables sin cargar en caminos raros**: push llamado desde forget o
   keys no tenia SHA ni AGE y escribia registros con campos vacios (tab
   colapsado). Arreglo de raiz: `tools_load` en cada comando.
4. **La guarda de rm de Claude Code** frena heredocs con `rm "$VAR/..."`:
   escribir `${VAR:?}` (ademas es mejor codigo).
5. **mawk** (el awk de Ubuntu) soporta `{n}` en regex: el validador anda.
6. **Un test que pasa a la primera merece romper el codigo a proposito**:
   asi aparecieron dos tests que no probaban lo que decian.
7. **La cuenta gh se desvio a AIDeepEconomics** sola; se verifico con
   `git credential fill` antes de cada push.
8. **Regla 29 contra el pedido de NICO**: "abri un PR grande al final" choca
   con "PR solo cuando la rama anda de punta a punta y paso la prueba
   manual". No se decidio sola: ver la pregunta abierta.

## 8. Preguntas abiertas para NICO

1. PR: lo abro como **borrador** hasta la prueba con B2 (recomendado, por
   la regla 29), o normal ya?
2. Release v0.24.8 y v0.25.0: cuando, y si v0.25.0 espera a la prueba B2.
3. Las carpetas de prueba en tu Google Drive (`relevio-test`,
   `relevio-test2`): las borro al terminar la prueba, o las queres mirar
   antes?

## 9. Cuadro completo

v0.25.0 esta terminada en codigo: el archivo encriptado local de la sesion
anterior ahora tiene copia fuera de la PC (carpeta sincronizada, Google
Drive o un bucket S3 como B2), todo encriptado incluso los nombres, con
verify, pull a una PC nueva, rotacion de la clave de recuperacion y sellos
de tiempo en Bitcoin. La seguridad se reviso dos veces y la raiz (age no
firma) quedo cubierta con validacion, rechazo de links y el sello de la
lista de llaves. La usabilidad quedo como pidio NICO: el setup es un solo
flujo con colores que termina solo, la nube se conecta pegando una sola
llave, y la guia le dice al agente que haga todo lo demas con formularios.
Falta la prueba real con B2, que necesita que NICO cree la cuenta, y
despues el PR y los releases, que son de NICO.
