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
}

export interface LadderResult {
  cards: number[];
  sum: number;
  winnerId: PlayerId;
}

export interface ScoreDelta {
  playerId: PlayerId;
  points: number;
  reason: "unique" | "ladder";
}

export interface RoundResult {
  canceled: number[];           // valores cancelados por repetición
  uniquePicks: Pick[];          // picks que no fueron cancelados
  ladders: LadderResult[];      // escaleras detectadas
  deltas: ScoreDelta[];         // puntos a sumar por jugador
}

/** Calcula el resultado de una ronda dados los picks. */
export function scoreRound(picks: ReadonlyArray<Pick>): RoundResult {
  const counts = new Map<number, number>();
  for (const p of picks) counts.set(p.cardValue, (counts.get(p.cardValue) ?? 0) + 1);

  const canceled: number[] = [];
  const uniqueValues: number[] = [];
  for (const [value, count] of counts) {
    if (count > 1) canceled.push(value);
    else uniqueValues.push(value);
  }
  canceled.sort((a, b) => a - b);
  uniqueValues.sort((a, b) => a - b);

  const uniquePicks = picks
    .filter((p) => !canceled.includes(p.cardValue))
    .slice()
    .sort((a, b) => a.cardValue - b.cardValue);

  const ladders = detectLadders(uniqueValues, uniquePicks);

  // Reglas de puntuación:
  //  * Cada carta única suma SIEMPRE su valor a quien la jugó.
  //  * Adicionalmente, por cada escalera detectada (>=3 cartas consecutivas),
  //    el dueño de la carta más baja recibe la SUMA total de la escalera
  //    como bono encima de su valor individual.
  const deltas: ScoreDelta[] = [];
  for (const p of uniquePicks) {
    deltas.push({ playerId: p.playerId, points: p.cardValue, reason: "unique" });
  }
  for (const l of ladders) {
    deltas.push({ playerId: l.winnerId, points: l.sum, reason: "ladder" });
  }

  return { canceled, uniquePicks, ladders, deltas };
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
