// Lógica pura del juego Michudice. Sin dependencias externas, fácil de testear.
// Reglas:
//  * Cartas con valor entre MIN_CARD y MAX_CARD.
//  * Si dos o más jugadores eligen el mismo valor, todas esas cartas se cancelan.
//  * Cartas únicas (no canceladas) suman su valor a quien la jugó.
//  * Si entre las cartas únicas hay una secuencia >=3 de valores consecutivos,
//    el jugador con la carta más baja de la secuencia recibe la suma de toda
//    la secuencia; las otras cartas de la secuencia NO suman por separado.

export const MIN_CARD = 3;
export const MAX_CARD = 9;
export const CARD_VALUES = Array.from(
  { length: MAX_CARD - MIN_CARD + 1 },
  (_, i) => MIN_CARD + i,
);
// Composición del mazo: N cartas con valor N (3..9).
export const DECK_COMPOSITION: ReadonlyArray<{ value: number; count: number }> =
  CARD_VALUES.map((v) => ({ value: v, count: v }));

/** Construye el mazo completo (orden creciente, sin barajar). */
export function buildDeck(): number[] {
  return DECK_COMPOSITION.flatMap(({ value, count }) =>
    Array.from({ length: count }, () => value),
  );
}

/** Baraja en sitio usando Fisher-Yates con un RNG opcional. */
export function shuffle<T>(arr: T[], rng: () => number = Math.random): T[] {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Reparte el mazo en N manos del mismo tamaño (descarta el sobrante). */
export function deal(deck: number[], playerCount: number): number[][] {
  const per = Math.floor(deck.length / playerCount);
  const hands: number[][] = [];
  for (let i = 0; i < playerCount; i++) {
    hands.push(deck.slice(i * per, (i + 1) * per));
  }
  return hands;
}

export type PlayerId = string;

export interface Pick {
  playerId: PlayerId;
  cardValue: number;
  seat?: number;
}

export interface LadderResult {
  cards: number[];
  sum: number;
  winnerId: PlayerId;
}

export interface ScoreDelta {
  playerId: PlayerId;
  points: number;
  reason: "unique" | "ladder" | "neighbor";
}

export interface SwapInfo {
  lowValue: number;
  highValue: number;
  lowOriginalPlayerId: PlayerId;
  highOriginalPlayerId: PlayerId;
}

export interface RoundResult {
  canceled: number[];           // valores cancelados por repetición
  uniquePicks: Pick[];          // picks que cuentan en la ronda (post-swap si aplica)
  ladders: LadderResult[];      // escaleras detectadas
  deltas: ScoreDelta[];         // puntos a sumar/restar por jugador
  rule: RuleKind | "normal";    // regla que aplicó esta ronda
  swap?: SwapInfo;              // detalle del intercambio cuando rule = 'swap'
}

/**
 * Reglas especiales que altera la ronda. Las juega el Michudice.
 *  - "subtract":  todos los puntos de la ronda se restan (incluida escalera).
 *                 Las cartas iguales siguen cancelándose.
 *  - "no_cancel": las cartas iguales NO se cancelan; cada copia suma para
 *                 su dueño y los duplicados pueden formar parte de la escalera.
 *  - "swap":      tras la cancelación, el dueño de la carta única más baja y
 *                 el de la más alta intercambian valores: el que bajó la
 *                 menor ahora suma el valor de la mayor y viceversa. La
 *                 escalera se detecta después del swap, y el bono va a quien
 *                 quede con el valor más bajo de la escalera.
 *  - "add_right" / "add_left" / "sub_right" / "sub_left":
 *                 Cada jugador (cuya carta NO fue cancelada) suma o resta el
 *                 valor jugado por su vecino de seat (right = seat+1,
 *                 left = seat-1, modular). Si la carta del vecino fue
 *                 cancelada, no se aplica el bonus para ese jugador.
 *                 La cancelación normal y la escalera siguen aplicando.
 *  - "cancel_even" / "cancel_odd":
 *                 Todas las cartas con valor par (o impar, según la regla)
 *                 se cancelan automáticamente, jugadas o no por uno o
 *                 varios jugadores. La cancelación por duplicado sigue
 *                 aplicando sobre el resto.
 *  - "none":      No hay variante. Se juega con las reglas base sin
 *                 modificador. Útil para que el Michudice cumpla la
 *                 obligación de jugar una carta de regla sin afectar el
 *                 puntaje. Internamente equivale a `null`.
 *  - "rotate_right" / "rotate_left":
 *                 ANTES del reveal, las cartas rotan: cada jugador entrega
 *                 su carta al vecino derecho (resp. izquierdo) y recibe la
 *                 del vecino izquierdo (resp. derecho). Tras la rotación
 *                 se aplica el flujo base de cancelación y escalera, así
 *                 que la carta que recibiste puede cancelarse si coincide
 *                 con otra. La rotación NO altera la regla aplicada al
 *                 puntaje (sign=+1, sin no_cancel, sin paridad).
 */
export type RuleKind =
  | "subtract"
  | "no_cancel"
  | "swap"
  | "add_right"
  | "add_left"
  | "sub_right"
  | "sub_left"
  | "cancel_even"
  | "cancel_odd"
  | "none"
  | "rotate_right"
  | "rotate_left";
export const RULE_KINDS: ReadonlyArray<RuleKind> = [
  "subtract",
  "no_cancel",
  "swap",
  "add_right",
  "add_left",
  "sub_right",
  "sub_left",
  "cancel_even",
  "cancel_odd",
  "none",
  "rotate_right",
  "rotate_left",
];

/** Calcula el resultado de una ronda dados los picks y la regla activa. */
export function scoreRound(
  picks: ReadonlyArray<Pick>,
  rule: RuleKind | null = null,
): RoundResult {
  // 'none' es la carta "sin modificador": equivale a no aplicar regla.
  if (rule === "none") rule = null;

  // Rotación: cada jugador entrega su carta al vecino indicado por la regla.
  // El cálculo posterior se hace sobre las picks rotadas.
  // rotate_right (dir=1): yo recibo la carta de seat-1 (mi vecino izquierdo).
  // rotate_left  (dir=-1): yo recibo la carta de seat+1 (mi vecino derecho).
  const rotateDir =
    rule === "rotate_right" ? 1
    : rule === "rotate_left" ? -1
    : 0;
  let workingPicks: ReadonlyArray<Pick> = picks;
  if (rotateDir !== 0) {
    const seated = picks
      .filter((p) => typeof p.seat === "number")
      .slice()
      .sort((a, b) => (a.seat as number) - (b.seat as number));
    const len = seated.length;
    if (len > 1) {
      workingPicks = seated.map((p, i) => {
        const sourceIdx = ((i - rotateDir) % len + len) % len;
        return {
          playerId: p.playerId,
          cardValue: seated[sourceIdx].cardValue,
          seat: p.seat,
        };
      });
    }
  }

  const counts = new Map<number, number>();
  for (const p of workingPicks) counts.set(p.cardValue, (counts.get(p.cardValue) ?? 0) + 1);

  const noCancel = rule === "no_cancel";
  const sign = rule === "subtract" ? -1 : 1;
  const cancelEven = rule === "cancel_even";
  const cancelOdd = rule === "cancel_odd";

  const canceled: number[] = [];
  const uniqueValues: number[] = [];
  for (const [value, count] of counts) {
    const parityCancel =
      (cancelEven && value % 2 === 0) || (cancelOdd && value % 2 !== 0);
    if (parityCancel) canceled.push(value);
    else if (count > 1 && !noCancel) canceled.push(value);
    else uniqueValues.push(value);
  }
  canceled.sort((a, b) => a - b);
  uniqueValues.sort((a, b) => a - b);

  let uniquePicks = workingPicks
    .filter((p) => noCancel || !canceled.includes(p.cardValue))
    .slice()
    .sort((a, b) => a.cardValue - b.cardValue);

  let swapInfo: SwapInfo | undefined;
  if (rule === "swap" && uniquePicks.length >= 2) {
    const low = uniquePicks[0];
    const high = uniquePicks[uniquePicks.length - 1];
    if (low.cardValue !== high.cardValue) {
      swapInfo = {
        lowValue: low.cardValue,
        highValue: high.cardValue,
        lowOriginalPlayerId: low.playerId,
        highOriginalPlayerId: high.playerId,
      };
      uniquePicks = uniquePicks.map((p, i) => {
        if (i === 0) return { playerId: high.playerId, cardValue: low.cardValue };
        if (i === uniquePicks.length - 1)
          return { playerId: low.playerId, cardValue: high.cardValue };
        return p;
      });
    }
  }

  const rawLadders = detectLadders(uniqueValues, uniquePicks);
  const ladders = rawLadders.map((l) => ({ ...l, sum: l.sum * sign }));

  const deltas: ScoreDelta[] = [];
  for (const p of uniquePicks) {
    deltas.push({ playerId: p.playerId, points: p.cardValue * sign, reason: "unique" });
  }
  for (const l of ladders) {
    deltas.push({ playerId: l.winnerId, points: l.sum, reason: "ladder" });
  }

  const neighborDir =
    rule === "add_right" || rule === "sub_right" ? 1
    : rule === "add_left" || rule === "sub_left" ? -1
    : 0;
  const neighborSign = rule === "sub_right" || rule === "sub_left" ? -1 : 1;
  if (neighborDir !== 0) {
    const seated = workingPicks
      .filter((p) => typeof p.seat === "number")
      .slice()
      .sort((a, b) => (a.seat as number) - (b.seat as number));
    const uniqueIds = new Set(uniquePicks.map((p) => p.playerId));
    const len = seated.length;
    for (let i = 0; i < len; i++) {
      const me = seated[i];
      if (!uniqueIds.has(me.playerId)) continue;
      const idx = ((i + neighborDir) % len + len) % len;
      const neighbor = seated[idx];
      if (!uniqueIds.has(neighbor.playerId)) continue;
      deltas.push({
        playerId: me.playerId,
        points: neighbor.cardValue * neighborSign,
        reason: "neighbor",
      });
    }
  }

  return {
    canceled,
    uniquePicks,
    ladders,
    deltas,
    rule: rule ?? "normal",
    ...(swapInfo ? { swap: swapInfo } : {}),
  };
}

function detectLadders(
  sortedUniqueValues: number[],
  uniquePicks: ReadonlyArray<Pick>,
): LadderResult[] {
  const ladders: LadderResult[] = [];
  let i = 0;
  while (i < sortedUniqueValues.length) {
    let j = i;
    while (
      j + 1 < sortedUniqueValues.length &&
      sortedUniqueValues[j + 1] === sortedUniqueValues[j] + 1
    )
      j++;
    const runLen = j - i + 1;
    if (runLen >= 3) {
      const cards = sortedUniqueValues.slice(i, j + 1);
      const sum = cards.reduce((a, b) => a + b, 0);
      const lowestCard = cards[0];
      const winner = uniquePicks.find((p) => p.cardValue === lowestCard);
      if (winner) ladders.push({ cards, sum, winnerId: winner.playerId });
    }
    i = j + 1;
  }
  return ladders;
}

/** Devuelve el id del siguiente Michudice según rotación por seat. */
export function nextMichudice(
  players: ReadonlyArray<{ id: PlayerId; seat: number; michudiceCount: number }>,
  currentSeat: number,
  target: number,
): PlayerId | null {
  const eligible = players.filter((p) => p.michudiceCount < target);
  if (eligible.length === 0) return null;
  const after = eligible
    .filter((p) => p.seat > currentSeat)
    .sort((a, b) => a.seat - b.seat);
  if (after.length > 0) return after[0].id;
  return eligible.slice().sort((a, b) => a.seat - b.seat)[0].id;
}

/** ¿La partida terminó? Todos llegaron al target de Michudice. */
export function isGameOver(
  players: ReadonlyArray<{ michudiceCount: number }>,
  target: number,
): boolean {
  return players.every((p) => p.michudiceCount >= target);
}
