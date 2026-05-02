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
- **Fin**: cuando alguien se queda sin cartas, o todos llegaron al
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
- `rooms(id, code, status, host_id, max_players, michudice_target, current_round, current_michudice)`
- `players(id, room_id, user_id, name, seat, score, michudice_count, hand_size)`
- `player_hands(player_id, hand int[])` ← **hand vive aquí**, RLS solo permite
  al dueño leerla. `players.hand_size` es público.
- `rounds(id, room_id, round_number, michudice_player_id, status)` con
  `status ∈ {picking, revealed, scored}`
- `round_picks(round_id, player_id, card_value)` ← RLS bloquea SELECT ajeno
  mientras `rounds.status = 'picking'`.
- `round_results(round_id, payload jsonb)` con cancelados, escaleras y deltas.

## Funciones SQL (todas SECURITY DEFINER)
- `create_room(p_name)` → crea sala + agrega host como player seat 0.
- `join_room(p_code, p_name)` → entra a sala en estado `lobby`.
- `start_game(p_room_id)` → solo host; baraja, reparte, crea ronda 1.
- `submit_pick(p_round_id, p_card_value)` → valida que la carta esté en la
  mano, la quita, registra pick. Permite cambiar antes del reveal.
- `reveal_round(p_round_id)` → cuando todos eligieron: corre `score_picks`,
  aplica deltas, marca status = `scored`. **No avanza** automáticamente.
- `advance_round(p_round_id)` → idempotente; el cliente lo dispara tras la
  animación de 5s para crear la siguiente ronda o terminar la partida.
- `redeal_hands(p_room_id)` → utilidad: re-reparte cartas si la sala quedó
  in_progress sin manos (debug / partidas antiguas).
- `score_picks(p_picks jsonb)` → puro, espejo SQL de `lib/game.ts:scoreRound`.

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
