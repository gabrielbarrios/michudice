"use client";

import { useTransition } from "react";
import { submitPickAction } from "@/app/actions";

interface Props {
  roundId: string;
  hand: number[];          // cartas que aún tiene el jugador
  myPick: number | null;   // carta que ya envió esta ronda (puede cambiarla)
  disabled: boolean;
}

export default function CardPicker({ roundId, hand, myPick, disabled }: Props) {
  const [pending, run] = useTransition();
  // Mostramos las cartas tal cual están en la mano (puede haber repetidas).
  // Si ya hay un pick, lo "devolvemos" visualmente añadiéndolo a la lista
  // así el jugador puede cambiar de elección.
  const display = myPick !== null ? [myPick, ...hand] : hand;
  const sorted = display.slice().sort((a, b) => a - b);

  if (sorted.length === 0) {
    return <p className="text-center text-white/60">No tienes cartas.</p>;
  }

  return (
    <div className="grid grid-cols-7 gap-3">
      {sorted.map((value, idx) => {
        const selected = myPick === value && idx === sorted.indexOf(myPick);
        return (
          <button
            key={`${value}-${idx}`}
            disabled={disabled || pending}
            onClick={() => run(() => submitPickAction(roundId, value))}
            className={
              "card-shape flex items-center justify-center text-3xl font-bold transition " +
              (selected
                ? "bg-amber-300 text-black ring-4 ring-amber-200"
                : "bg-white text-black hover:-translate-y-1 hover:shadow-xl") +
              (disabled || pending ? " opacity-60 cursor-not-allowed" : "")
            }
          >
            {value}
          </button>
        );
      })}
    </div>
  );
}
