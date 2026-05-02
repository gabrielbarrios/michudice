# 🐱 Michudice

Juego de cartas multijugador en tiempo real. Next.js (App Router) + Supabase
(Auth anónima + Postgres + Realtime).

## 🎮 Reglas

- Cartas con valor **3..9** (mazo conceptual: N cartas con valor N).
- Cada ronda, cada jugador elige una carta **en secreto**.
- Al revelar:
  - Cartas con valores **repetidos se cancelan** (no suman).
  - Cartas únicas suman su valor a quien la jugó.
  - Cada carta única suma SIEMPRE su valor a quien la jugó.
  - Si entre las cartas únicas hay una **escalera de ≥3 valores consecutivos**,
    el jugador con la carta **más baja** recibe además la **suma total** de la
    escalera como bono (encima de su valor individual). Las otras cartas de
    la escalera siguen sumando individualmente para sus dueños.
- Existe el rol **Michudice** (gato líder) que rota cada ronda.
- La partida termina cuando **todos** han sido Michudice 2 veces.
- Mínimo 3 / máximo 9 jugadores.

## 🏗️ Estructura

```
app/
  actions.ts              # Server actions (RPC a Supabase)
  page.tsx                # Home (crear / unirse a sala)
  room/[code]/page.tsx    # Servidor: carga estado inicial
  globals.css
components/
  RoomClient.tsx          # Suscribe Realtime; orquesta Lobby/GameBoard/Results
  Lobby.tsx               # Espera de jugadores
  GameBoard.tsx           # Tablero, picks, marcadores, resultado de ronda
  CardPicker.tsx          # Selector de carta privado
  Results.tsx             # Pantalla final
lib/
  game.ts                 # Lógica pura del juego (scoring, escaleras, rotación)
  game.test.ts            # Unit tests (vitest)
  supabase/
    browser.ts            # Cliente para componentes "use client"
    server.ts             # Cliente para Server Components / actions
    service.ts            # Service role (bypassa RLS)
middleware.ts             # Sesión anónima de Supabase
supabase/migrations/
  0001_init.sql           # Schema, RLS, RPC, score_picks (espejo SQL)
types/db.ts               # Tipos de filas
```

## ⚙️ Setup

1. Crea proyecto en [supabase.com](https://supabase.com).
2. Habilita **Anonymous sign-ins** en Auth → Providers.
3. Copia `.env.local.example` a `.env.local` y rellena URLs/keys.
4. Aplica el schema:
   ```bash
   # opción A: Supabase CLI
   supabase db push
   # opción B: pega supabase/migrations/0001_init.sql en SQL Editor y ejecútalo
   ```
5. Instala y levanta:
   ```bash
   npm install
   npm run dev
   ```
6. Abre `http://localhost:3000` en varias pestañas/dispositivos para probar.

## 🛡️ Anti-trampa

Tres capas:

1. **RLS sobre `round_picks`**: un jugador solo ve su propio pick mientras la
   ronda esté en estado `picking`. Al pasar a `revealed` los miembros pueden
   ver las cartas de todos.
2. **Mutaciones por funciones SECURITY DEFINER**: nadie escribe `players.score`
   ni `rounds.status` directamente. Toda transición pasa por `submit_pick`,
   `reveal_round`, `start_game`, etc. (Postgres functions).
3. **Scoring server-side**: `reveal_round` recolecta picks, calcula deltas con
   `score_picks` (espejo SQL del módulo `lib/game.ts`) y aplica los puntos en
   la misma transacción. El cliente no puede falsificar puntuaciones.

## 🔄 Sincronización Realtime

El cliente se suscribe a `postgres_changes` filtrando por `room_id` para:
`rooms`, `players`, `rounds`, `round_picks`, `round_results`. Cuando el último
jugador envía su pick, el cliente intenta `reveal_round`; la función es
idempotente y solo procede cuando ya hay tantos picks como jugadores.

## 📈 Flujo de una partida (3 jugadores)

1. Alice crea sala → recibe código `ABCD12`.
2. Bob y Carol entran con el código.
3. Alice presiona **Iniciar**. Se crea la primera ronda; el Michudice es Alice.
4. Cada uno elige una carta (Alice 5, Bob 6, Carol 7).
5. Al picar el último, `reveal_round` corre:
   - No hay repetidos.
   - Cada uno suma su carta: Alice +5, Bob +6, Carol +7.
   - {5,6,7} es escalera → Alice recibe 18 puntos extra (bono).
   - Total: Alice 23, Bob 6, Carol 7.
6. Avanza la ronda; Bob es ahora Michudice.
7. Tras 6 rondas (3 jugadores × 2 turnos cada uno), la sala pasa a `finished`
   y se muestra el podio.

## 🧪 Tests

```bash
npm run test
```

Cubre cancelaciones, escaleras simples y dobles, escaleras rotas por cartas
canceladas, rotación de Michudice y condición de fin.

## 🚀 Para escalar / extender

- **Variantes con mazo finito**: añadir `decks` y `hands` (cartas restantes por
  jugador) y forzar `submit_pick` a descontar de la mano. La constante
  `DECK_COMPOSITION` en `lib/game.ts` ya describe el mazo.
- **Reglas alternativas**: `score_picks` recibe los picks como JSON; agregar
  flags por sala (`rooms.variant`) y ramificar dentro de la función SQL.
- **Reconexión / kick**: añadir heartbeat por `presence` de Realtime y permitir
  al host expulsar jugadores inactivos.
- **Persistencia / historial**: ya queda guardado en `round_results.payload`,
  basta exponer un endpoint para revisar partidas pasadas.
- **Auth real**: reemplazar `signInAnonymously` en `middleware.ts` por
  proveedores OAuth.
- **i18n**: textos están centralizados en los componentes; mover a un diccionario.
- **Tests E2E**: Playwright con varios contextos para simular jugadores
  concurrentes contra una instancia local de Supabase.
# michudice
