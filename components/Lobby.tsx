"use client";

import { useTransition } from "react";
import { startGameAction } from "@/app/actions";
import type { PlayerRow, RoomRow } from "@/types/db";

interface Props {
  room: RoomRow;
  players: PlayerRow[];
  meId: string;
}

export default function Lobby({ room, players, meId }: Props) {
  const [pending, start] = useTransition();
  const me = players.find((p) => p.id === meId);
  const isHost = me?.user_id === room.host_id;
  const canStart = players.length >= 3 && players.length <= room.max_players;

  return (
    <main className="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-12">
      <div className="rounded-2xl bg-white/5 p-6 ring-1 ring-white/10">
        <p className="text-sm uppercase tracking-widest text-white/50">Código</p>
        <p className="font-display text-5xl tracking-[0.4em]">{room.code}</p>
        <p className="mt-2 text-sm text-white/60">
          Comparte el código. Mínimo 3, máximo {room.max_players} jugadores.
        </p>
      </div>

      <section>
        <h2 className="mb-3 text-lg font-semibold">
          Jugadores ({players.length}/{room.max_players})
        </h2>
        <ul className="grid gap-2 sm:grid-cols-2">
          {players.map((p) => (
            <li
              key={p.id}
              className="flex items-center justify-between rounded-md bg-white/5 px-4 py-2 ring-1 ring-white/10"
            >
              <span>
                {p.name} {p.user_id === room.host_id && <span>👑</span>}
                {p.id === meId && <span className="ml-1 text-emerald-300">(tú)</span>}
              </span>
              <span className="text-xs text-white/40">asiento {p.seat + 1}</span>
            </li>
          ))}
        </ul>
      </section>

      {isHost ? (
        <button
          disabled={!canStart || pending}
          onClick={() => start(() => startGameAction(room.id))}
          className="w-full rounded-md bg-emerald-500 px-4 py-3 font-semibold text-black hover:bg-emerald-400 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-white/40"
        >
          {pending ? "Iniciando..." : canStart ? "Iniciar partida" : "Esperando jugadores..."}
        </button>
      ) : (
        <p className="text-center text-white/60">
          Esperando que el anfitrión inicie la partida.
        </p>
      )}
    </main>
  );
}
