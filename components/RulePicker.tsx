"use client";

import { useTransition } from "react";
import type { RuleKind } from "@/types/db";
import { submitRulePickAction } from "@/app/actions";

interface Props {
  roundId: string;
  hand: RuleKind[];
  myPick: RuleKind | null;
}

export const RULE_LABEL: Record<RuleKind, string> = {
  subtract: "📉 Los puntos se restan",
  no_cancel: "🔁 Las iguales no se cancelan",
  swap: "🔀 Intercambio menor/mayor",
  add_right: "➡️➕ Suma al vecino derecho",
  add_left: "⬅️➕ Suma al vecino izquierdo",
  sub_right: "➡️➖ Resta al vecino derecho",
  sub_left: "⬅️➖ Resta al vecino izquierdo",
  cancel_even: "🔢 Pares se cancelan",
  cancel_odd: "🔢 Impares se cancelan",
  none: "⚪ Sin variante",
  rotate_right: "🔃 Cartas rotan a la derecha",
  rotate_left: "🔄 Cartas rotan a la izquierda",
};
export const RULE_DESC: Record<RuleKind, string> = {
  subtract:
    "Cada carta única (y la escalera) RESTA en lugar de sumar.",
  no_cancel:
    "Las cartas con el mismo valor NO se cancelan: cada copia suma y pueden usarse en escalera.",
  swap:
    "Tras cancelar repetidos, el dueño de la carta más baja y el de la más alta intercambian valores. La escalera se evalúa después del intercambio.",
  add_right:
    "Cada jugador suma a su carta el valor de la carta del jugador a su derecha. Si la del vecino fue cancelada, no se aplica.",
  add_left:
    "Cada jugador suma a su carta el valor de la carta del jugador a su izquierda. Si la del vecino fue cancelada, no se aplica.",
  sub_right:
    "Cada jugador resta a su carta el valor de la carta del jugador a su derecha. Si la del vecino fue cancelada, no se aplica.",
  sub_left:
    "Cada jugador resta a su carta el valor de la carta del jugador a su izquierda. Si la del vecino fue cancelada, no se aplica.",
  cancel_even:
    "Toda carta con valor PAR (4, 6, 8) se cancela y no suma puntos. La cancelación por duplicado sigue aplicando sobre las impares.",
  cancel_odd:
    "Toda carta con valor IMPAR (3, 5, 7, 9) se cancela y no suma puntos. La cancelación por duplicado sigue aplicando sobre las pares.",
  none:
    "No hay variante: la ronda se puntúa con las reglas base sin modificador.",
  rotate_right:
    "Antes del reveal, cada jugador entrega su carta al vecino derecho (recibe la del izquierdo). La carta que recibas puede cancelarse si choca con otra igual.",
  rotate_left:
    "Antes del reveal, cada jugador entrega su carta al vecino izquierdo (recibe la del derecho). La carta que recibas puede cancelarse si choca con otra igual.",
};

export default function RulePicker({ roundId, hand, myPick }: Props) {
  const [pending, run] = useTransition();
  const display: RuleKind[] = myPick ? [myPick, ...hand] : [...hand];

  if (display.length === 0) {
    return (
      <p className="text-center text-white/60">
        No tienes cartas de regla disponibles.
      </p>
    );
  }

  return (
    <div className="grid gap-3 sm:grid-cols-2">
      {display.map((kind, idx) => {
        const selected = myPick === kind && idx === display.indexOf(myPick);
        return (
          <button
            key={`${kind}-${idx}`}
            disabled={pending}
            onClick={() => run(() => submitRulePickAction(roundId, kind))}
            className={
              "rounded-xl p-4 text-left ring-1 transition " +
              (selected
                ? "bg-amber-300 text-black ring-amber-200"
                : "bg-white/5 text-white ring-white/10 hover:bg-white/10")
            }
          >
            <div className="text-base font-semibold">{RULE_LABEL[kind]}</div>
            <div className={"mt-1 text-xs " + (selected ? "text-black/70" : "text-white/60")}>
              {RULE_DESC[kind]}
            </div>
          </button>
        );
      })}
    </div>
  );
}
