"use client";

import type { PlayerRow, RoomRow, RoundResultRow } from "@/types/db";

interface Props {
  room: RoomRow;
  players: PlayerRow[];
  lastResult: RoundResultRow | null;
}

export default function Results({ room, players }: Props) {
  const sorted = players.slice().sort((a, b) => b.score - a.score);
  const top = sorted[0];

  return (
    <main className="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-12 text-center">
      <h1 className="font-display text-5xl">🏆 Fin de la partida</h1>
      <p className="text-white/70">Sala {room.code}</p>

      {top && (
        <div className="rounded-2xl bg-amber-300/10 p-6 ring-1 ring-amber-300/30">
          <p className="text-sm uppercase tracking-widest text-amber-200">
            Ganador
          </p>
          <p className="font-display text-3xl">{top.name}</p>
          <p className="text-amber-100">{top.score} puntos</p>
        </div>
      )}

      <ol className="space-y-2 text-left">
        {sorted.map((p, i) => (
          <li
            key={p.id}
            className="flex items-center justify-between rounded-md bg-white/5 px-4 py-2 ring-1 ring-white/10"
          >
            <span>
              <b className="mr-2">{i + 1}.</b>
              {p.name}
            </span>
            <span>{p.score} pts</span>
          </li>
        ))}
      </ol>

      <a
        href="/"
        className="inline-block rounded-md bg-emerald-500 px-4 py-3 font-semibold text-black hover:bg-emerald-400"
      >
        Volver al inicio
      </a>
    </main>
  );
}
