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
