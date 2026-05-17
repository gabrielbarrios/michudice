import { describe, expect, it } from "vitest";
import {
  buildDeck,
  deal,
  isGameOver,
  nextMichudice,
  scoreRound,
  shuffle,
  type Pick,
} from "./game";

const p = (id: string, v: number): Pick => ({ playerId: id, cardValue: v });
const ps = (id: string, v: number, seat: number): Pick => ({
  playerId: id,
  cardValue: v,
  seat,
});

type Delta = { playerId: string; points: number };
function totalsByPlayer(deltas: Delta[]): Record<string, number> {
  return deltas.reduce<Record<string, number>>((acc, d) => {
    acc[d.playerId] = (acc[d.playerId] ?? 0) + d.points;
    return acc;
  }, {});
}

describe("scoreRound", () => {
  it("cancela cartas repetidas", () => {
    const r = scoreRound([p("a", 7), p("b", 7), p("c", 5)]);
    expect(r.canceled).toEqual([7]);
    expect(r.deltas).toEqual([{ playerId: "c", points: 5, reason: "unique" }]);
  });

  it("suma cada carta única cuando no hay escaleras", () => {
    const r = scoreRound([p("a", 3), p("b", 5), p("c", 9)]);
    expect(r.canceled).toEqual([]);
    expect(r.deltas).toHaveLength(3);
    expect(r.deltas.every((d) => d.reason === "unique")).toBe(true);
  });

  it("escalera: cada carta suma para su dueño + bono total para la más baja", () => {
    // 4+5+6 = 15. a (carta 4) recibe 4 + 15 = 19; b recibe 5; c recibe 6.
    const r = scoreRound([p("a", 4), p("b", 5), p("c", 6)]);
    expect(r.ladders).toHaveLength(1);
    expect(r.ladders[0]).toEqual({ cards: [4, 5, 6], sum: 15, winnerId: "a" });
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 19, b: 5, c: 6 });
  });

  it("escalera de 4: dueño de la más baja gana suma + su carta; resto suma su carta", () => {
    const r = scoreRound([p("a", 3), p("b", 4), p("c", 5), p("d", 6)]);
    expect(r.ladders[0].sum).toBe(18);
    expect(r.ladders[0].winnerId).toBe("a");
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 21, b: 4, c: 5, d: 6 });
  });

  it("escalera + único fuera de la escalera coexisten", () => {
    const r = scoreRound([p("a", 3), p("b", 4), p("c", 5), p("d", 9)]);
    // ladder 3+4+5=12. a gana 3+12=15. b=4, c=5, d=9.
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 15, b: 4, c: 5, d: 9 });
  });

  it("escalera rota por carta cancelada no cuenta como escalera", () => {
    const r = scoreRound([p("a", 4), p("b", 5), p("c", 5), p("d", 6)]);
    expect(r.canceled).toEqual([5]);
    expect(r.ladders).toEqual([]);
    // 4 y 6 únicos sueltos
    expect(r.deltas).toEqual([
      { playerId: "a", points: 4, reason: "unique" },
      { playerId: "d", points: 6, reason: "unique" },
    ]);
  });

  it("escalera que no arranca en la primera carta única", () => {
    // a juega 3 (suelto), b/c/d juegan 5/6/7 (escalera)
    // ladder 5+6+7=18. b gana 5+18=23, c=6, d=7, a=3.
    const r = scoreRound([p("a", 3), p("b", 5), p("c", 6), p("d", 7)]);
    expect(r.ladders).toHaveLength(1);
    expect(r.ladders[0].cards).toEqual([5, 6, 7]);
    expect(r.ladders[0].winnerId).toBe("b");
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 3, b: 23, c: 6, d: 7 });
  });

  it("dos escaleras separadas en la misma ronda", () => {
    const r = scoreRound([
      p("a", 3), p("b", 4), p("c", 5),
      p("d", 7), p("e", 8), p("f", 9),
    ]);
    expect(r.ladders).toHaveLength(2);
    // ladder1 sum=12 → a gana 3+12=15, b=4, c=5
    // ladder2 sum=24 → d gana 7+24=31, e=8, f=9
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 15, b: 4, c: 5, d: 31, e: 8, f: 9 });
  });

  it("nada suma cuando todos repiten", () => {
    const r = scoreRound([p("a", 6), p("b", 6), p("c", 6)]);
    expect(r.deltas).toEqual([]);
    expect(r.canceled).toEqual([6]);
  });
});

describe("nextMichudice", () => {
  const players = [
    { id: "p1", seat: 0, michudiceCount: 1 },
    { id: "p2", seat: 1, michudiceCount: 0 },
    { id: "p3", seat: 2, michudiceCount: 2 },
  ];
  it("rota al siguiente seat elegible", () => {
    expect(nextMichudice(players, 0, 2)).toBe("p2");
  });
  it("salta a quien ya cumplió target", () => {
    expect(nextMichudice(players, 1, 2)).toBe("p1");
  });
  it("vuelve al primero si no hay más adelante", () => {
    expect(nextMichudice(players, 2, 2)).toBe("p1");
  });
  it("retorna null si todos cumplieron", () => {
    const all = players.map((x) => ({ ...x, michudiceCount: 2 }));
    expect(nextMichudice(all, 0, 2)).toBeNull();
  });
});

describe("scoreRound con reglas especiales", () => {
  it("subtract invierte el signo de cada delta", () => {
    // 4+5+6=15 escalera → a recibe 4+15 = 19, b=5, c=6 (positivos)
    // con subtract: a=-19, b=-5, c=-6
    const r = scoreRound(
      [p("a", 4), p("b", 5), p("c", 6)],
      "subtract",
    );
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: -19, b: -5, c: -6 });
    expect(r.ladders[0].sum).toBe(-15);
    expect(r.rule).toBe("subtract");
  });

  it("subtract preserva la cancelación de duplicados", () => {
    const r = scoreRound([p("a", 7), p("b", 7), p("c", 5)], "subtract");
    expect(r.canceled).toEqual([7]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ c: -5 });
  });

  it("swap: intercambia dueños de la carta única más baja y la más alta", () => {
    // picks 8,5,6,7,8,4 → 8 cancela; únicos 4,5,6,7.
    // swap: dueño de 4 (a) ahora suma 7; dueño de 7 (d) ahora suma 4.
    // ladder 4+5+6+7 = 22; el "4 efectivo" lo tiene d → bono para d.
    // a = 7, b = 5, c = 6, d = 4 + 22 = 26. (e,f tenían 8 → cancelados.)
    const r = scoreRound(
      [p("a", 4), p("b", 5), p("c", 6), p("d", 7), p("e", 8), p("f", 8)],
      "swap",
    );
    expect(r.canceled).toEqual([8]);
    expect(r.swap).toEqual({
      lowValue: 4,
      highValue: 7,
      lowOriginalPlayerId: "a",
      highOriginalPlayerId: "d",
    });
    expect(r.ladders).toHaveLength(1);
    expect(r.ladders[0].cards).toEqual([4, 5, 6, 7]);
    expect(r.ladders[0].sum).toBe(22);
    expect(r.ladders[0].winnerId).toBe("d");
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 7, b: 5, c: 6, d: 26 });
  });

  it("swap sin escalera: solo intercambia los extremos", () => {
    // únicos 3, 5, 9 → sin escalera. swap: a (3) suma 9, c (9) suma 3, b queda 5.
    const r = scoreRound(
      [p("a", 3), p("b", 5), p("c", 9)],
      "swap",
    );
    expect(r.ladders).toEqual([]);
    expect(r.swap).toEqual({
      lowValue: 3,
      highValue: 9,
      lowOriginalPlayerId: "a",
      highOriginalPlayerId: "c",
    });
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 9, b: 5, c: 3 });
  });

  it("swap con un solo único no hace nada", () => {
    // a y b cancelan; solo queda c con 7.
    const r = scoreRound(
      [p("a", 5), p("b", 5), p("c", 7)],
      "swap",
    );
    expect(r.swap).toBeUndefined();
    expect(totalsByPlayer(r.deltas)).toEqual({ c: 7 });
  });

  it("swap con todas canceladas no aplica", () => {
    const r = scoreRound([p("a", 6), p("b", 6)], "swap");
    expect(r.swap).toBeUndefined();
    expect(r.deltas).toEqual([]);
  });

  it("add_right: cada jugador suma el valor del vecino derecho", () => {
    // seats 0..3 con cartas 3,5,7,9. Sin cancelados. No hay escalera.
    // right = seat+1 mod 4. a→b, b→c, c→d, d→a.
    // Totales: a=3+5=8, b=5+7=12, c=7+9=16, d=9+3=12.
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 5, 1), ps("c", 7, 2), ps("d", 9, 3)],
      "add_right",
    );
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 8, b: 12, c: 16, d: 12 });
  });

  it("add_left: cada jugador suma el valor del vecino izquierdo", () => {
    // left = seat-1 mod 4. a→d, b→a, c→b, d→c.
    // Totales: a=3+9=12, b=5+3=8, c=7+5=12, d=9+7=16.
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 5, 1), ps("c", 7, 2), ps("d", 9, 3)],
      "add_left",
    );
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 12, b: 8, c: 12, d: 16 });
  });

  it("sub_right: resta el valor del vecino derecho", () => {
    // a=3-5=-2, b=5-7=-2, c=7-9=-2, d=9-3=6.
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 5, 1), ps("c", 7, 2), ps("d", 9, 3)],
      "sub_right",
    );
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: -2, b: -2, c: -2, d: 6 });
  });

  it("sub_left: resta el valor del vecino izquierdo", () => {
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 5, 1), ps("c", 7, 2), ps("d", 9, 3)],
      "sub_left",
    );
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: -6, b: 2, c: 2, d: 2 });
  });

  it("vecino cancelado no contribuye y cancelado no recibe bonus", () => {
    // seats 0..3: a=4,b=7,c=7,d=5. b y c cancelan (mismos 7).
    // únicos: a (4), d (5). right(a)=b cancelado → a no recibe.
    // right(d)=a único → d recibe a.cardValue = 4. d total = 5+4=9.
    // a total = 4 (sin neighbor bonus).
    // b y c cancelados → no aparecen en deltas.
    const r = scoreRound(
      [ps("a", 4, 0), ps("b", 7, 1), ps("c", 7, 2), ps("d", 5, 3)],
      "add_right",
    );
    expect(r.canceled).toEqual([7]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 4, d: 9 });
  });

  it("regla de vecino + escalera: ambos bonos coexisten", () => {
    // 4 jugadores en escalera 3,4,5,6. Ladder sum=18 → ganador a (3).
    // add_right: a→b(4), b→c(5), c→d(6), d→a(3).
    // a = 3 + 18 (ladder) + 4 (neighbor) = 25
    // b = 4 + 5 = 9, c = 5 + 6 = 11, d = 6 + 3 = 9.
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 4, 1), ps("c", 5, 2), ps("d", 6, 3)],
      "add_right",
    );
    expect(r.ladders[0].sum).toBe(18);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 25, b: 9, c: 11, d: 9 });
  });

  it("cancel_even: cartas pares no suman, las impares se mantienen", () => {
    // 3,4,5,6,7 → 4 y 6 cancelados por paridad. 3,5,7 únicos.
    const r = scoreRound(
      [p("a", 3), p("b", 4), p("c", 5), p("d", 6), p("e", 7)],
      "cancel_even",
    );
    expect(r.canceled.sort((x, y) => x - y)).toEqual([4, 6]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 3, c: 5, e: 7 });
  });

  it("cancel_odd: cartas impares no suman, las pares se mantienen", () => {
    const r = scoreRound(
      [p("a", 3), p("b", 4), p("c", 5), p("d", 6), p("e", 7)],
      "cancel_odd",
    );
    expect(r.canceled.sort((x, y) => x - y)).toEqual([3, 5, 7]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ b: 4, d: 6 });
  });

  it("rotate_right: cada jugador puntúa la carta de su vecino izquierdo", () => {
    // seats 0..3 cartas 3,5,7,9. rotate_right: a recibe d's 9, b recibe a's 3,
    // c recibe b's 5, d recibe c's 7. Sin duplicados, sin escalera (no consecutivos).
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 5, 1), ps("c", 7, 2), ps("d", 9, 3)],
      "rotate_right",
    );
    expect(r.canceled).toEqual([]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 9, b: 3, c: 5, d: 7 });
  });

  it("rotate_left: cada jugador puntúa la carta de su vecino derecho", () => {
    const r = scoreRound(
      [ps("a", 3, 0), ps("b", 5, 1), ps("c", 7, 2), ps("d", 9, 3)],
      "rotate_left",
    );
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 5, b: 7, c: 9, d: 3 });
  });

  it("rotate_right puede cancelar al chocar dos cartas iguales tras la rotación", () => {
    // a=4 seat 0, b=7 seat 1, c=4 seat 2, d=9 seat 3.
    // rotate_right: a recibe d's 9, b recibe a's 4, c recibe b's 7, d recibe c's 4.
    // Picks rotadas: a=9, b=4, c=7, d=4 → 4 cancela (b y d).
    // Únicos: a=9, c=7 → 9+7=16 total para ellos.
    const r = scoreRound(
      [ps("a", 4, 0), ps("b", 7, 1), ps("c", 4, 2), ps("d", 9, 3)],
      "rotate_right",
    );
    expect(r.canceled).toEqual([4]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 9, c: 7 });
  });

  it("rotate_right forma escalera con las cartas rotadas", () => {
    // a=5,b=4,c=3,d=9 en seats 0..3. rotate_right: a←d=9, b←a=5, c←b=4, d←c=3.
    // Rotadas: a=9, b=5, c=4, d=3 → únicos 3,4,5,9 → escalera 3,4,5 sum=12.
    // Lowest card 3 lo tiene d → d gana 3+12=15. a=9, b=5, c=4.
    const r = scoreRound(
      [ps("a", 5, 0), ps("b", 4, 1), ps("c", 3, 2), ps("d", 9, 3)],
      "rotate_right",
    );
    expect(r.ladders).toHaveLength(1);
    expect(r.ladders[0].cards).toEqual([3, 4, 5]);
    expect(r.ladders[0].winnerId).toBe("d");
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 9, b: 5, c: 4, d: 15 });
  });

  it("none: equivale a no aplicar regla (mismo resultado que null)", () => {
    const picks = [p("a", 4), p("b", 5), p("c", 6)];
    const r = scoreRound(picks, "none");
    const baseline = scoreRound(picks);
    expect(r.rule).toBe("normal");
    expect(r.deltas).toEqual(baseline.deltas);
    expect(r.canceled).toEqual(baseline.canceled);
    expect(r.ladders).toEqual(baseline.ladders);
  });

  it("cancel_even sigue aplicando duplicado sobre impares", () => {
    // 4 (par, cancelado) + 5,5 (duplicado, cancelado) + 7 (único impar).
    const r = scoreRound(
      [p("a", 4), p("b", 5), p("c", 5), p("d", 7)],
      "cancel_even",
    );
    expect(r.canceled.sort((x, y) => x - y)).toEqual([4, 5]);
    expect(totalsByPlayer(r.deltas)).toEqual({ d: 7 });
  });

  it("double_low: el dueño de la carta única más baja suma el doble", () => {
    // únicos 4, 6, 8 → a (4) suma 4×2=8, b (6) suma 6, c (8) suma 8.
    const r = scoreRound(
      [p("a", 4), p("b", 6), p("c", 8)],
      "double_low",
    );
    expect(r.canceled).toEqual([]);
    expect(r.ladders).toEqual([]);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 8, b: 6, c: 8 });
    expect(r.rule).toBe("double_low");
  });

  it("double_low + escalera: doble individual y bono se acumulan", () => {
    // únicos 4,5,6,8 → escalera 4-5-6 sum=15 ganador a (4).
    // a = 4×2 (doble) + 15 (ladder) = 23. b=5, c=6, d=8.
    const r = scoreRound(
      [p("a", 4), p("b", 5), p("c", 6), p("d", 8)],
      "double_low",
    );
    expect(r.ladders).toHaveLength(1);
    expect(r.ladders[0].sum).toBe(15);
    const totals = totalsByPlayer(r.deltas);
    expect(totals).toEqual({ a: 23, b: 5, c: 6, d: 8 });
  });

  it("double_low con un solo único: ese único se dobla", () => {
    // a y b cancelan; queda c con 7 → 7×2 = 14.
    const r = scoreRound(
      [p("a", 5), p("b", 5), p("c", 7)],
      "double_low",
    );
    expect(r.canceled).toEqual([5]);
    expect(totalsByPlayer(r.deltas)).toEqual({ c: 14 });
  });

  it("double_low sin únicos: sin deltas", () => {
    const r = scoreRound(
      [p("a", 6), p("b", 6)],
      "double_low",
    );
    expect(r.deltas).toEqual([]);
    expect(r.canceled).toEqual([6]);
  });

  it("no_cancel: las cartas iguales siguen sumando y forman escalera", () => {
    // 5,5,6,7 sin cancelación: cada uno suma su carta + escalera 5+6+7=18
    // ganador de la escalera es uno de los 5 (el primero encontrado).
    const r = scoreRound(
      [p("a", 5), p("b", 5), p("c", 6), p("d", 7)],
      "no_cancel",
    );
    expect(r.canceled).toEqual([]);
    expect(r.ladders).toHaveLength(1);
    expect(r.ladders[0].cards).toEqual([5, 6, 7]);
    expect(r.ladders[0].sum).toBe(18);
    const totals = totalsByPlayer(r.deltas);
    // a o b recibe el bono: una de las dos llaves debe tener 5+18=23
    const ladderWinner = r.ladders[0].winnerId;
    expect([totals.a, totals.b]).toContain(23);
    expect(totals[ladderWinner]).toBe(23);
    expect(totals.c).toBe(6);
    expect(totals.d).toBe(7);
  });
});

describe("buildDeck / shuffle / deal", () => {
  it("el mazo tiene 42 cartas con composición correcta", () => {
    const deck = buildDeck();
    expect(deck.length).toBe(3 + 4 + 5 + 6 + 7 + 8 + 9);
    for (let v = 3; v <= 9; v++) {
      expect(deck.filter((c) => c === v).length).toBe(v);
    }
  });
  it("shuffle preserva el multiset", () => {
    const deck = buildDeck();
    const shuffled = shuffle(deck);
    expect(shuffled.slice().sort()).toEqual(deck.slice().sort());
  });
  it("deal reparte tamaños iguales y descarta el sobrante", () => {
    const hands = deal(buildDeck(), 5);
    expect(hands).toHaveLength(5);
    expect(hands.every((h) => h.length === 8)).toBe(true);
    // 5 × 8 = 40, sobran 2 cartas (descartadas)
  });
});

describe("isGameOver", () => {
  it("termina cuando todos llegaron al target", () => {
    expect(
      isGameOver([{ michudiceCount: 2 }, { michudiceCount: 2 }], 2),
    ).toBe(true);
  });
  it("no termina si alguien va atrasado", () => {
    expect(
      isGameOver([{ michudiceCount: 2 }, { michudiceCount: 1 }], 2),
    ).toBe(false);
  });
});
