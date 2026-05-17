# Michudice — guía para Claude Code

Juego de cartas multijugador en tiempo real. Stack: **Next.js 14 (App Router) +
Supabase (Postgres + Auth anónima + Realtime) + Tailwind**. Todo en TypeScript.

## Reglas del juego (canónicas)
- Mazo de 42 cartas: `N` cartas con valor `N` para `N ∈ [3..9]`. Al iniciar la
  partida se baraja y se reparten `floor(42/jugadores)` cartas a cada uno.
- Cada ronda, cada jugador elige una carta de su mano en secreto. Cuando todos
  eligen, se revelan a la vez.
- **Cancelación**: cartas con valores repetidos no suman.
- **Únicas**: cada carta única siempre suma su valor a quien la jugó.
- **Escalera**: si entre las cartas únicas hay ≥3 valores consecutivos, el dueño
  de la más baja recibe además la SUMA de la escalera como bono (encima de su
  carta individual). El resto sigue sumando su carta individualmente.
- **Michudice**: rol que rota cada ronda por orden de `seat`.
- **Cartas de regla** (mazo aparte): **TODOS** los jugadores empiezan con 2
  cartas de regla en mano (no solo el Michudice). El reparto inicial se hace
  en `start_game` y reparte 2 cartas a cada jugador por orden de `seat`.
  Cada ronda solo el Michudice de turno puede elegir una de sus 2 cartas
  (`submit_rule_pick` valida `player_id = michudice_player_id`, error
  `'only michudice can pick rule'`); se revela junto con las cartas de número
  y modifica la puntuación de esa ronda. Después del reveal se repone una
  carta SOLO al Michudice tomándola del mazo central (`rooms.rule_deck`); el
  resto de jugadores conserva sus cartas hasta que les toque ser Michudice.
  Tipos disponibles:
  - `subtract`: los puntos de la ronda se RESTAN (incluida la escalera). Las
    cartas iguales siguen cancelándose.
  - `no_cancel`: las cartas con el mismo valor NO se cancelan, cada una suma
    para su dueño y los duplicados pueden formar parte de la escalera.
  - `swap`: tras la cancelación normal, el dueño de la carta única más baja
    y el de la más alta INTERCAMBIAN valores para sumar. La escalera se
    detecta sobre los valores efectivos post-swap, así que el bono va a
    quien quede con el valor más bajo de la escalera (ej.: picks
    8,5,6,7,8,4 → 8 cancela; el dueño original de 4 suma 7, el de 7 suma
    4 + bono de escalera 4+5+6+7=22). Si solo queda un valor único o
    todos cancelan, el swap no aplica.
  - `add_right` / `add_left` / `sub_right` / `sub_left`: cada jugador (cuya
    carta NO fue cancelada) suma o resta el valor jugado por su vecino de
    seat (right = seat+1 mod N, left = seat-1 mod N). Si la carta del
    vecino fue cancelada, no se aplica el bonus para ese jugador. La
    cancelación normal y la escalera siguen funcionando; el bonus de
    vecino se acumula como un delta extra (`reason = 'neighbor'`).
    Para que esto funcione, `reveal_round` inyecta `seat` en cada pick
    JSON antes de llamar a `score_picks` (ver 0014).
  - `cancel_even` / `cancel_odd`: toda carta con valor par (o impar,
    según la regla) se cancela y no suma. La cancelación por duplicado
    sigue aplicando sobre las cartas que sobrevivan al filtro de paridad
    (ver 0015).
  - `none`: "Sin variante" — la ronda se puntúa con las reglas base sin
    modificador. Internamente `score_picks` normaliza `'none'` a `null`
    al inicio (`nullif(p_rule, 'none')`), por lo que el resultado tiene
    `rule: 'normal'`. Útil para que el Michudice cumpla la obligación
    de jugar carta sin alterar el puntaje (ver 0016).
  - `rotate_right` / `rotate_left`: ANTES de cancelación/escalera, cada
    jugador entrega su carta al vecino derecho (resp. izquierdo) y
    recibe la del izquierdo (resp. derecho). El resto del flujo (cancel
    duplicados, escalera, deltas) corre sobre las picks rotadas — es
    decir, la carta que recibiste puede cancelarse si choca con otra ya
    rotada. La rotación no flipea signos ni desactiva cancelación
    (ver 0017).
  - `double_low`: el dueño de la carta única más baja suma su valor el
    DOBLE. El resto de las cartas únicas suman normal. La cancelación
    por duplicado aplica como siempre; la escalera funciona igual y su
    bono se acumula con el doble del individual (ej.: picks 4,5,6,8 →
    dueño del 4 recibe 2×4 + escalera 15 = 23). Si solo queda un único,
    ese se dobla; si todas cancelan, no hay deltas (ver 0020).
  Mazo: la composición depende de `rooms.deck_mode` (ver 0018), elegido al
  crear la sala desde la home. Modos:
   - `classic`  : `max(5, jugadores+1)` de cada regla (default).
   - `single`   : 1 copia de cada tipo.
   - `negative` : 3 de cada + 6 de las que restan (`subtract`, `sub_right`, `sub_left`).
   - `positive` : 3 de cada + 1 de las que restan.
   - `pairs`    : 2 de cada.
  Cuando `rooms.rule_deck` se vacía, `rooms.rule_discard` se baraja y
  reemplaza al mazo (ver 0010).
  **Cómo agregar una nueva carta de regla:**
  1. Añadir el nuevo `kind` al CHECK de `round_rule_picks.rule_kind` y al
     `RuleSchema` en `app/actions.ts` (`z.enum([...])`).
  2. Extender `build_rule_deck` para incluir la nueva carta en el mazo.
  3. Implementar el efecto en `score_picks(p_picks, p_rule)` (rama por
     `p_rule = '<kind>'`) y en su espejo TS `lib/game.ts:scoreRound`.
  4. Si el efecto cambia signos o cancelaciones, replicar la lógica de
     `v_sign` / `v_no_cancel` en ambos sitios.
  5. Añadir UI en `CardPicker`/`GameBoard` para que el Michudice la vea.
  - Si una sala vieja quedó sin cartas de regla (creada antes de aplicar las
    migraciones nuevas), el host puede tocar **"Repartir cartas de regla"**
    en el banner amarillo: dispara `redealRuleHandsAction` →
    `redeal_rule_hands(p_room_id)` (migración 0011), que rebaraja el mazo,
    reparte 2 cartas a cada jugador y borra el `round_rule_pick` actual.
    Requisito: aplicar 0009 → 0010 → 0011 → 0012 en el SQL Editor de
    Supabase (son idempotentes). Sin esas migraciones la RPC falla con
    `Could not find the function public.redeal_rule_hands in the schema cache`.
- **Fin**: cuando alguien se queda sin cartas de número, o todos llegaron al
  `michudice_target` (default 2), lo que ocurra primero.
- 3 ≤ jugadores ≤ 9.

## Arquitectura
```
app/
  page.tsx                 Home: crear/unirse a sala
  room/[code]/page.tsx     Carga inicial server-side
  actions.ts               Server actions → RPC a Supabase
  globals.css              Tailwind + animación flip + overlay reveal
components/
  RoomClient.tsx           Suscribe Realtime + polling de respaldo
  Lobby.tsx                Lista de jugadores + botón Iniciar (host)
  GameBoard.tsx            Tablero, picks, modal de reveal de 5s
  CardPicker.tsx           Selector de carta desde la mano
  PlayedCard.tsx           Carta con flip 3D (boca abajo / cara)
  Results.tsx              Pantalla final
lib/
  game.ts                  Lógica pura: scoreRound, ladders, deck, deal
  game.test.ts             Tests vitest
  supabase/{browser,server,service}.ts
middleware.ts              Garantiza sesión anónima
supabase/migrations/
  0001_init.sql            Schema canónico
  0002..0008_*.sql         Patches incrementales (ver "Migraciones")
types/db.ts                Tipos de filas
```

## Modelo de datos (resumen)
- `rooms(id, code, status, host_id, max_players, michudice_target, current_round, current_michudice, rule_deck text[])`
  El `rule_deck` guarda las cartas de regla aún no repartidas.
- `players(id, room_id, user_id, name, seat, score, michudice_count, hand_size, rule_hand_size)`
- `player_hands(player_id, hand int[])` ← mano numérica, RLS solo dueño.
- `player_rule_hands(player_id, hand text[])` ← mano de cartas de regla, RLS solo dueño.
- `rounds(id, room_id, round_number, michudice_player_id, status, rule_played text|null)` con
  `status ∈ {picking, revealed, scored}` y `rule_played` se setea al revelar.
- `round_picks(round_id, player_id, card_value)` ← RLS bloquea SELECT ajeno
  mientras `rounds.status = 'picking'`.
- `round_rule_picks(round_id PK, player_id, rule_kind)` ← una sola fila por
  ronda (la del Michudice). RLS espeja `round_picks`: solo el dueño hasta el
  reveal.
- `round_results(round_id, payload jsonb)` con cancelados, escaleras, deltas y
  la regla aplicada.

## Funciones SQL (todas SECURITY DEFINER)
- `create_room(p_name)` → crea sala + agrega host como player seat 0.
- `join_room(p_code, p_name)` → entra a sala en estado `lobby`.
- `start_game(p_room_id)` → solo host; baraja, reparte, crea ronda 1.
- `submit_pick(p_round_id, p_card_value)` → valida que la carta esté en la
  mano, la quita, registra pick. Permite cambiar antes del reveal.
- `submit_rule_pick(p_round_id, p_rule_kind)` → solo el Michudice. Mismo
  patrón que submit_pick pero sobre `player_rule_hands` y `round_rule_picks`.
- `reveal_round(p_round_id)` → cuando todos eligieron Y el Michudice eligió
  regla: corre `score_picks(picks, rule)`, aplica deltas (con el signo según
  la regla), repone una carta de regla al Michudice tomándola de
  `rooms.rule_deck`, marca status = `scored`. **No avanza** automáticamente.
- `advance_round(p_round_id)` → idempotente; el cliente lo dispara tras la
  animación de 5s para crear la siguiente ronda o terminar la partida.
- `redeal_hands(p_room_id)` → utilidad: re-reparte cartas si la sala quedó
  in_progress sin manos (debug / partidas antiguas).
- `score_picks(p_picks jsonb, p_rule text default null)` → puro, espejo SQL
  de `lib/game.ts:scoreRound`. Acepta `'subtract'`, `'no_cancel'` o NULL.

⚠️ **Cuidado con slicing de arrays en plpgsql**: `arr[i:j]` PRESERVA la cota
inferior, así que `result[1]` puede ser NULL. Construir runs con
`array_append` en un loop por índice (ver `score_picks`).

⚠️ **OUT params no pueden chocar con nombres de columnas**: por eso los OUT
params de `create_room`/`join_room` están prefijados con `out_`.

## Anti-trampa (3 capas)
1. **RLS** en `round_picks` (solo veo el mío hasta que la ronda esté revealed)
   y en `player_hands` (solo el dueño ve su mano).
2. **SECURITY DEFINER**: nadie escribe `score`, `status`, `hand`, etc.
   directamente. Todo pasa por funciones SQL validadas.
3. **Scoring server-side** en `reveal_round` → el cliente no puede inflar
   puntos.

## Realtime + polling
Se suscriben todos los miembros al canal `room:${room.id}` con
`postgres_changes` filtrado por `room_id`. Hay polling de respaldo cada 1.5–2s
para `rooms`, `players`, `rounds`, `round_picks`, `round_results` y la mano
propia (`player_hands`), por si Realtime no está habilitado en el proyecto
Supabase. Cuando el último jugador envía pick, el cliente dispara
`reveal_round` (idempotente). Tras 5s de animación, el HOST llama
`advance_round`.

## Convenciones
- TypeScript estricto. Tipos de DB en `types/db.ts` deben mantenerse
  sincronizados con las migraciones.
- Server actions en `app/actions.ts` con validación `zod`. Cada una llama
  `ensureAuth(supabase)` antes de la RPC para garantizar sesión anónima.
- Componentes "use client" solo cuando hace falta estado/efectos. Toda lectura
  inicial idealmente desde Server Components (`page.tsx`).
- Estilos: Tailwind + clases utilitarias. Animación flip definida en
  `globals.css` (`.flip-card`, `.flip-inner`, `.flip-front`, `.flip-back`).
- Server Actions no acceden a tablas directamente — siempre vía RPC. Esto
  centraliza permisos y evita reescribir lógica en JS.

## Comandos útiles
```bash
npm install
npm run dev          # arranca Next en :3000
npm run build
npm run test         # vitest sobre lib/game.test.ts
```
Variables de entorno en `.env.local`:
```
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...   # solo se usa server-side
```

## Migraciones
Aplicar en orden si vas desde cero. Si ya tienes la base, los patches sueltos
funcionan idempotentes:
```
0001_init.sql               schema base (ya incluye fixes de score_picks y regla final)
0002_fix_rls.sql            RLS más permisiva en rooms/players/rounds
0003_fix_ambiguity.sql      OUT params prefijados con out_
0004_deck.sql               player_hands + repartición + RLS estricta
0005_redeal.sql             función redeal_hands para destrabar partidas
0006_fix_ladder.sql         fix slicing de arrays en score_picks
0007_ladder_bonus.sql       cambio de regla: cartas en escalera siguen sumando
0008_split_advance.sql      separa reveal_round (scored) y advance_round
0009_rule_cards.sql         cartas de regla del Michudice + score_picks(rule)
0010_recycle_rule_deck.sql  reciclaje de rule_deck desde rule_discard
0011_redeal_rules.sql       redeal_rule_hands para salas viejas
0012_random_first_michudice.sql  primer Michudice aleatorio al iniciar
0013_swap_rule.sql          tercera carta de regla 'swap' + score_picks lo soporta
0014_neighbor_rules.sql     cuatro reglas de vecino (add/sub × right/left); reveal_round inyecta seat
0015_parity_rules.sql       reglas cancel_even / cancel_odd; cancela cartas por paridad
0016_no_modifier_rule.sql   regla 'none' (sin variante); score_picks normaliza 'none' → null
0017_rotate_rules.sql       reglas rotate_right / rotate_left; rota picks por seat antes del scoring
0018_deck_modes.sql         modo de mazo configurable (rooms.deck_mode); build_rule_deck por modo
0019_fix_none_rule.sql      defensivo: re-aplica score_picks con nullif('none') para garantizar reglas base
0020_double_low_rule.sql    carta de regla 'double_low': dueño de la carta única más baja suma doble
```
**Setup limpio mínimo**: `0001_init.sql` + `0004_deck.sql` + `0005_redeal.sql`
+ `0008_split_advance.sql`.

## Cosas que NO hacer
- No escribir directo a `players.score`, `players.hand_size`, `rounds.status`
  o `player_hands.hand` desde el cliente. Crear/usar una RPC.
- No agregar `hand` a `players` (rompe el aislamiento del anti-trampa).
- No usar `arr[i:j]` en plpgsql sin cuidar el reindexado.
- No quitar `ensureAuth` de las server actions (rompe la primera petición
  cuando middleware aún no creó sesión).
- No exponer `SUPABASE_SERVICE_ROLE_KEY` al cliente.

## Extender el juego
- **Variantes de scoring**: añadir `rooms.variant text` y bifurcar dentro de
  `score_picks` (mantener la versión TS sincronizada).
- **Reconexión / kick**: agregar `presence` de Realtime para detectar
  jugadores caídos y `kick_player(player_id)` para el host.
- **Historial**: ya está todo en `round_results.payload`; basta una vista.
- **Auth real**: cambiar `signInAnonymously` por OAuth en `middleware.ts`.

## Memoria reciente (cosas aprendidas en esta sesión)
- Anonymous sign-ins debe estar habilitado en Supabase → Auth → Providers.
- Si las migraciones nuevas no se aplican, partidas viejas se quedan en estado
  inconsistente; usar `redeal_hands` o resetear `rooms.status = 'lobby'`.
- En Supabase con publishable keys (`sb_publishable_*`), todo lo demás funciona
  igual que con `anon key` clásica.
