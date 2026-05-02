"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import type {
  PlayerRow,
  RoomRow,
  RoundPickRow,
  RoundResultRow,
  RoundRow,
} from "@/types/db";
import CardPicker from "./CardPicker";
import PlayedCard from "./PlayedCard";
import {
  advanceRoundAction,
  redealHandsAction,
  tryRevealAction,
} from "@/app/actions";

interface Props {
  room: RoomRow;
  players: PlayerRow[];
  round: RoundRow | null;
  picks: RoundPickRow[];
  result: RoundResultRow | null;
  meId: string;
  myHand: number[];
}

const REVEAL_DURATION_MS = 5000;

export default function GameBoard({
  room,
  players,
  round,
  picks,
  result,
  meId,
  myHand,
}: Props) {
  const [, startReveal] = useTransition();
  const [, startAdvance] = useTransition();
  const advanceTriggered = useRef<string | null>(null);

  // Cuando todos eligen, dispara reveal una vez por ronda.
  useEffect(() => {
    if (!round) return;
    if (round.status !== "picking") return;
    if (picks.length >= players.length) {
      startReveal(() => tryRevealAction(round.id));
    }
  }, [round, picks.length, players.length]);

  // Cuando la ronda llega a 'scored' / 'revealed', mostramos cartas 5s y luego
  // avanzamos. Solo el host dispara advance_round; los demás esperan a la
  // suscripción / polling para ver la nueva ronda. La función SQL es idempotente.
  const isHost =
    players.find((p) => p.id === meId)?.user_id === room.host_id;
  const isRevealing =
    !!round && (round.status === "revealed" || round.status === "scored");

  useEffect(() => {
    if (!round || !isRevealing) return;
    if (advanceTriggered.current === round.id) return;
    advanceTriggered.current = round.id;
    const t = setTimeout(() => {
      if (isHost) {
        startAdvance(() => advanceRoundAction(round.id));
      }
    }, REVEAL_DURATION_MS);
    return () => clearTimeout(t);
  }, [round?.id, isRevealing, isHost]);

  if (!round) {
    return (
      <main className="mx-auto max-w-2xl px-6 py-20 text-center">
        <p>Cargando ronda...</p>
      </main>
    );
  }

  const myPick = picks.find((p) => p.player_id === meId)?.card_value ?? null;
  const michudice = players.find((p) => p.id === round.michudice_player_id);
  const cardsLeft = Math.max(...players.map((p) => p.hand_size ?? 0), 0);
  const noHandsDealt = players.every((p) => (p.hand_size ?? 0) === 0);

  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-8 px-6 py-10">
      <header className="flex items-center justify-between">
        <div>
          <p className="text-xs uppercase tracking-widest text-white/40">Sala</p>
          <p className="font-display text-2xl tracking-[0.3em]">{room.code}</p>
        </div>
        <div className="text-right">
          <p className="text-xs uppercase tracking-widest text-white/40">Ronda</p>
          <p className="font-display text-2xl">{round.round_number}</p>
          <p className="text-xs text-white/40">{cardsLeft} cartas/jugador</p>
        </div>
      </header>

      <div className="rounded-2xl bg-amber-300/10 p-4 text-center ring-1 ring-amber-300/30">
        🐱 Michudice de la ronda:{" "}
        <span className="font-semibold text-amber-200">
          {michudice?.name ?? "?"}
        </span>
      </div>

      {noHandsDealt && (
        <div className="rounded-2xl bg-rose-500/10 p-4 text-center ring-1 ring-rose-300/30">
          <p className="text-rose-200">No hay cartas repartidas en esta sala.</p>
          {isHost ? (
            <button
              onClick={() => redealHandsAction(room.id)}
              className="mt-3 rounded-md bg-rose-400 px-4 py-2 font-semibold text-black hover:bg-rose-300"
            >
              Repartir cartas ahora
            </button>
          ) : (
            <p className="mt-2 text-xs text-rose-200/70">
              Pide al anfitrión que reparta las cartas.
            </p>
          )}
        </div>
      )}

      <section>
        <h2 className="mb-3 text-sm uppercase tracking-widest text-white/50">
          Jugadores
        </h2>
        <ul className="grid gap-2 sm:grid-cols-2">
          {players.map((p) => {
            const theirCard = picks.find((x) => x.player_id === p.id)?.card_value;
            // Mientras se está eligiendo, solo se muestra carta boca abajo
            // para los que ya eligieron. Cuando se revela, todos voltean.
            const cardValue = theirCard ?? null;
            const showOwnFace = p.id === meId && cardValue !== null && !isRevealing;
            return (
              <li
                key={p.id}
                className="flex items-center justify-between rounded-md bg-white/5 px-4 py-2 ring-1 ring-white/10"
              >
                <div>
                  <span>{p.name}</span>
                  {p.id === meId && <span className="ml-2 text-emerald-300">(tú)</span>}
                  {p.id === round.michudice_player_id && <span className="ml-2">🐱</span>}
                </div>
                <div className="flex items-center gap-3">
                  <span className="text-xs text-white/40">
                    {p.hand_size ?? 0} 🂠
                  </span>
                  <span className="text-sm text-white/60">{p.score} pts</span>
                  <PlayedCard
                    value={cardValue}
                    revealed={showOwnFace || isRevealing}
                  />
                </div>
              </li>
            );
          })}
        </ul>
      </section>

      {round.status === "picking" && (
        <section>
          <h2 className="mb-3 text-sm uppercase tracking-widest text-white/50">
            Tu carta
          </h2>
          <CardPicker
            roundId={round.id}
            hand={myHand}
            myPick={myPick}
            disabled={false}
          />
          <p className="mt-3 text-center text-sm text-white/50">
            {picks.length}/{players.length} jugadores listos
          </p>
        </section>
      )}

      {isRevealing && (
        <RevealOverlay
          players={players}
          picks={picks}
          result={result}
          durationMs={REVEAL_DURATION_MS}
        />
      )}
    </main>
  );
}

function RevealOverlay({
  players,
  picks,
  result,
  durationMs,
}: {
  players: PlayerRow[];
  picks: RoundPickRow[];
  result: RoundResultRow | null;
  durationMs: number;
}) {
  const nameOf = (id: string) =>
    players.find((p) => p.id === id)?.name ?? "?";
  const sortedPicks = picks.slice().sort((a, b) => a.card_value - b.card_value);
  const ladders = result?.payload.ladders ?? [];
  const canceled = result?.payload.canceled ?? [];
  const deltas = result?.payload.deltas ?? [];

  return (
    <div className="reveal-overlay fixed inset-0 z-50 flex items-center justify-center px-4">
      <div className="reveal-pop max-w-xl w-full space-y-5 rounded-2xl bg-feltDark p-6 ring-1 ring-white/15">
        <div className="flex items-center justify-between">
          <h2 className="font-display text-2xl">Revelando ronda</h2>
          <span className="text-xs text-white/40">{durationMs / 1000}s</span>
        </div>

        <div className="flex flex-wrap items-center justify-center gap-3">
          {sortedPicks.map((p) => (
            <div key={p.id} className="flex flex-col items-center gap-1">
              <PlayedCard value={p.card_value} revealed />
              <span className="text-xs text-white/50">
                {nameOf(p.player_id)}
              </span>
            </div>
          ))}
        </div>

        {result ? (
          <div className="space-y-2 text-sm">
            {canceled.length > 0 && (
              <p className="text-white/70">
                ❌ Cancelados: {canceled.join(", ")}
              </p>
            )}
            {ladders.map((l, i) => (
              <p key={i} className="text-amber-200">
                🪜 Escalera {l.cards.join(" → ")} = +{l.sum} para{" "}
                <b>{nameOf(l.winner_id)}</b>
              </p>
            ))}
            {deltas.length > 0 ? (
              <ul className="space-y-1 text-white/80">
                {deltas.map((d, i) => (
                  <li key={i}>
                    <span className="text-emerald-300">
                      {nameOf(d.player_id)}
                    </span>{" "}
                    +{d.points} ({d.reason === "ladder" ? "escalera" : "carta"})
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-white/60">Nadie sumó esta ronda.</p>
            )}
          </div>
        ) : (
          <p className="text-center text-white/60">Calculando puntaje...</p>
        )}

        <div className="h-1 overflow-hidden rounded-full bg-white/10">
          <div className="countdown-bar h-full bg-amber-300" />
        </div>
      </div>
    </div>
  );
}
