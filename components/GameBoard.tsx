"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import type {
  PlayerRow,
  RoomRow,
  RoundPickRow,
  RoundResultRow,
  RoundRow,
  RoundRulePickRow,
  RuleKind,
} from "@/types/db";
import CardPicker from "./CardPicker";
import PlayedCard from "./PlayedCard";
import RulePicker, { RULE_LABEL, RULE_DESC } from "./RulePicker";
import {
  advanceRoundAction,
  redealHandsAction,
  redealRuleHandsAction,
  runBotsAction,
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
  myRuleHand: RuleKind[];
  rulePick: RoundRulePickRow | null;
}

const REVEAL_DURATION_MS = 10000;

export default function GameBoard({
  room,
  players,
  round,
  picks,
  result,
  meId,
  myHand,
  myRuleHand,
  rulePick,
}: Props) {
  const [, startReveal] = useTransition();
  const [, startAdvance] = useTransition();
  const [, startBots] = useTransition();
  const advanceTriggered = useRef<string | null>(null);
  const botsTriggered = useRef<string | null>(null);

  // Cuando todos eligen número Y el Michudice eligió regla, intenta revelar.
  useEffect(() => {
    if (!round) return;
    if (round.status !== "picking") return;
    if (picks.length >= players.length && rulePick) {
      startReveal(() => tryRevealAction(round.id));
    }
  }, [round, picks.length, players.length, rulePick]);

  const isHost = players.find((p) => p.id === meId)?.user_id === room.host_id;

  // Solo el host dispara la acción de bots: detecta picks pendientes de bots
  // y/o regla pendiente cuando el Michudice es bot. La server action es
  // idempotente, pero usamos un ref para no spamearla en cada render.
  useEffect(() => {
    if (!round || round.status !== "picking" || !isHost) return;
    const botMissingPick = players.some(
      (p) => p.is_bot && !picks.some((x) => x.player_id === p.id),
    );
    const michudice = players.find((p) => p.id === round.michudice_player_id);
    const michudiceBotMissingRule = !!michudice?.is_bot && !rulePick;
    if (!botMissingPick && !michudiceBotMissingRule) return;
    const key = `${round.id}:${picks.length}:${rulePick ? 1 : 0}`;
    if (botsTriggered.current === key) return;
    botsTriggered.current = key;
    startBots(() => runBotsAction(round.id));
  }, [round, picks, rulePick, players, isHost]);
  const isRevealing =
    !!round && (round.status === "revealed" || round.status === "scored");
  const isMichudice = !!round && round.michudice_player_id === meId;

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
  const myRulePick =
    rulePick && rulePick.player_id === meId ? rulePick.rule_kind : null;
  const michudice = players.find((p) => p.id === round.michudice_player_id);
  const cardsLeft = Math.max(...players.map((p) => p.hand_size ?? 0), 0);
  const noHandsDealt = players.every((p) => (p.hand_size ?? 0) === 0);

  // Orden por seat para el listado y cálculo de vecinos: right = seat+1, left = seat-1.
  const sortedPlayers = players.slice().sort((a, b) => a.seat - b.seat);
  const myIdx = sortedPlayers.findIndex((p) => p.id === meId);
  const N = sortedPlayers.length;
  const rightNeighborId =
    myIdx >= 0 && N > 1 ? sortedPlayers[(myIdx + 1) % N].id : null;
  const leftNeighborId =
    myIdx >= 0 && N > 1 ? sortedPlayers[(myIdx - 1 + N) % N].id : null;
  const rightNeighborName =
    sortedPlayers.find((p) => p.id === rightNeighborId)?.name ?? null;
  const leftNeighborName =
    sortedPlayers.find((p) => p.id === leftNeighborId)?.name ?? null;

  return (
    <main className="mx-auto flex max-w-5xl flex-col gap-8 px-6 py-10">
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
        <p className="mt-1 text-xs text-amber-100/70">
          {rulePick
            ? "Carta de regla colocada boca abajo · se revela junto a las cartas"
            : isMichudice
              ? "👇 Debes elegir UNA carta de regla (obligatorio)"
              : "Esperando que el Michudice elija su carta de regla..."}
        </p>
      </div>

      {isMichudice && round.status === "picking" && !rulePick && (
        <div className="reveal-pop rounded-2xl bg-amber-400/15 p-4 text-center ring-2 ring-amber-300/50">
          <p className="text-amber-100">
            ⚡ Eres el Michudice. Cada ronda <b>debes</b> jugar 1 carta de regla.
          </p>
          {myRuleHand.length === 0 && (
            <div className="mt-3">
              <p className="text-sm text-amber-200/80">
                No tienes cartas de regla disponibles.
              </p>
              {isHost ? (
                <button
                  onClick={() => redealRuleHandsAction(room.id)}
                  className="mt-2 rounded-md bg-amber-400 px-4 py-2 font-semibold text-black hover:bg-amber-300"
                >
                  Repartir cartas de regla
                </button>
              ) : (
                <p className="mt-1 text-xs text-amber-100/70">
                  Pide al anfitrión que reparta las cartas de regla.
                </p>
              )}
            </div>
          )}
        </div>
      )}

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
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm uppercase tracking-widest text-white/50">
            Jugadores
          </h2>
          {(leftNeighborName || rightNeighborName) && (
            <p className="text-xs text-white/50">
              {leftNeighborName && (
                <span className="mr-3">
                  ⬅️ tu izquierda:{" "}
                  <b className="text-sky-200">{leftNeighborName}</b>
                </span>
              )}
              {rightNeighborName && (
                <span>
                  tu derecha:{" "}
                  <b className="text-fuchsia-200">{rightNeighborName}</b> ➡️
                </span>
              )}
            </p>
          )}
        </div>
        <ul className="grid gap-2 sm:grid-cols-2">
          {sortedPlayers.map((p) => {
            const theirCard = picks.find((x) => x.player_id === p.id)?.card_value;
            const cardValue = theirCard ?? null;
            const showOwnFace = p.id === meId && cardValue !== null && !isRevealing;
            const isLeft = p.id === leftNeighborId;
            const isRight = p.id === rightNeighborId;
            const ringClass = isLeft
              ? "ring-2 ring-sky-300/50"
              : isRight
                ? "ring-2 ring-fuchsia-300/50"
                : "ring-1 ring-white/10";
            return (
              <li
                key={p.id}
                className={
                  "flex items-center justify-between rounded-md bg-white/5 px-4 py-2 " +
                  ringClass
                }
              >
                <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                  <span className="text-xs text-white/30">#{p.seat + 1}</span>
                  <span>{p.name}</span>
                  {p.is_bot && <span title="Bot">🤖</span>}
                  {p.id === meId && (
                    <span className="text-emerald-300">(tú)</span>
                  )}
                  {p.id === round.michudice_player_id && <span>🐱</span>}
                  {isLeft && (
                    <span className="rounded-full bg-sky-400/20 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-sky-200">
                      ⬅️ izquierda
                    </span>
                  )}
                  {isRight && (
                    <span className="rounded-full bg-fuchsia-400/20 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-fuchsia-200">
                      derecha ➡️
                    </span>
                  )}
                </div>
                <div className="flex items-center gap-3">
                  <span className="text-xs text-white/40">
                    {p.hand_size ?? 0} 🂠
                  </span>
                  <span className="text-xs text-amber-200/60">
                    {p.rule_hand_size ?? 0} 📜
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
        <div
          className={
            "grid gap-6 " +
            (isMichudice ? "lg:grid-cols-[1fr_320px]" : "")
          }
        >
          <section className="rounded-2xl bg-white/5 p-5 ring-1 ring-white/10">
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
              {" · "}
              {rulePick ? "regla lista 📜" : "regla pendiente 📜"}
            </p>
          </section>

          {isMichudice && (
            <section className="rounded-2xl bg-amber-300/5 p-5 ring-2 ring-amber-300/40">
              <div className="mb-3 flex items-center justify-between">
                <h2 className="text-sm font-semibold uppercase tracking-widest text-amber-200">
                  📜 Carta de regla
                </h2>
                <span
                  className={
                    "rounded-full px-2 py-0.5 text-xs " +
                    (rulePick
                      ? "bg-emerald-400/20 text-emerald-200"
                      : "bg-amber-400/30 text-amber-100")
                  }
                >
                  {rulePick ? "✓ elegida" : "obligatoria"}
                </span>
              </div>
              {myRuleHand.length === 0 && !myRulePick ? (
                <p className="text-center text-sm text-amber-100/70">
                  No tienes cartas de regla. Pide al anfitrión repartir desde el
                  banner amarillo de arriba.
                </p>
              ) : (
                <RulePicker
                  roundId={round.id}
                  hand={myRuleHand}
                  myPick={myRulePick}
                />
              )}
              <p className="mt-3 text-center text-xs text-amber-100/60">
                Se coloca boca abajo. Se voltea junto a las cartas de número.
              </p>
            </section>
          )}
        </div>
      )}

      {isRevealing && (
        <RevealOverlay
          players={players}
          picks={picks}
          result={result}
          rule={round.rule_played ?? rulePick?.rule_kind ?? null}
          durationMs={REVEAL_DURATION_MS}
        />
      )}
    </main>
  );
}

const ROLL_DURATION_MS = 2500;
const ROLL_TICK_MS = 80;
const RANDOM_RANGE = [3, 4, 5, 6, 7, 8, 9];

function RevealOverlay({
  players,
  picks,
  result,
  rule,
  durationMs,
}: {
  players: PlayerRow[];
  picks: RoundPickRow[];
  result: RoundResultRow | null;
  rule: RuleKind | null;
  durationMs: number;
}) {
  const nameOf = (id: string) =>
    players.find((p) => p.id === id)?.name ?? "?";
  const sortedPicks = picks.slice().sort((a, b) => a.card_value - b.card_value);
  const ladders = result?.payload.ladders ?? [];
  const canceled = result?.payload.canceled ?? [];
  const deltas = result?.payload.deltas ?? [];
  const randomCancelValue = result?.payload.random_cancel_value ?? null;
  const isRandomRule = rule === "cancel_random";

  // Animación de "ruleta" para cancel_random: cicla 3..9 hasta que arriba el
  // resultado del servidor; luego corre ROLL_DURATION_MS y se detiene en el
  // valor real. Mientras dura el roll ocultamos cartas/puntajes para que la
  // sorpresa sea legible.
  const [rollDone, setRollDone] = useState(!isRandomRule);
  const [rollTick, setRollTick] = useState(0);

  useEffect(() => {
    if (!isRandomRule) {
      setRollDone(true);
      return;
    }
    if (randomCancelValue == null) return;
    setRollDone(false);
    const interval = setInterval(() => {
      setRollTick((t) => t + 1);
    }, ROLL_TICK_MS);
    const timeout = setTimeout(() => {
      clearInterval(interval);
      setRollDone(true);
    }, ROLL_DURATION_MS);
    return () => {
      clearInterval(interval);
      clearTimeout(timeout);
    };
  }, [isRandomRule, randomCancelValue]);

  const rollingDisplay =
    RANDOM_RANGE[rollTick % RANDOM_RANGE.length];

  return (
    <div className="reveal-overlay fixed inset-0 z-50 flex items-center justify-center px-4">
      <div className="reveal-pop max-w-xl w-full space-y-5 rounded-2xl bg-feltDark p-6 ring-1 ring-white/15">
        <div className="flex items-center justify-between">
          <h2 className="font-display text-2xl">Revelando ronda</h2>
          <span className="text-xs text-white/40">{durationMs / 1000}s</span>
        </div>

        {rule && (
          <div className="rounded-xl bg-amber-300/10 p-3 ring-1 ring-amber-300/30">
            <p className="text-xs uppercase tracking-widest text-amber-200/70">
              Carta de regla
            </p>
            <p className="font-semibold text-amber-100">{RULE_LABEL[rule]}</p>
            <p className="text-xs text-amber-100/70">{RULE_DESC[rule]}</p>
          </div>
        )}

        {isRandomRule && (
          <div className="flex flex-col items-center gap-2 rounded-xl bg-rose-500/10 p-4 ring-1 ring-rose-300/30">
            <p className="text-xs uppercase tracking-widest text-rose-200/70">
              Número que se cancela
            </p>
            <div
              className={
                "random-roll flex h-20 w-20 items-center justify-center rounded-2xl font-display text-5xl font-bold ring-2 " +
                (rollDone
                  ? "random-roll-stopped bg-rose-400 text-black ring-rose-200"
                  : "bg-white/10 text-white ring-white/30")
              }
            >
              {rollDone ? randomCancelValue ?? "?" : rollingDisplay}
            </div>
            <p className="text-xs text-rose-100/70">
              {rollDone
                ? "Esas cartas se cancelan en esta ronda."
                : "Sorteando…"}
            </p>
          </div>
        )}

        {rollDone && (
          <>
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
                    🪜 Escalera {l.cards.join(" → ")} = {l.sum >= 0 ? "+" : ""}
                    {l.sum} para <b>{nameOf(l.winner_id)}</b>
                  </p>
                ))}
                {deltas.length > 0 ? (
                  <ul className="space-y-1 text-white/80">
                    {deltas.map((d, i) => (
                      <li key={i}>
                        <span className="text-emerald-300">
                          {nameOf(d.player_id)}
                        </span>{" "}
                        {d.points >= 0 ? "+" : ""}
                        {d.points} (
                        {d.reason === "ladder"
                          ? "escalera"
                          : d.reason === "neighbor"
                            ? "vecino"
                            : "carta"}
                        )
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
          </>
        )}

        <div className="h-1 overflow-hidden rounded-full bg-white/10">
          <div className="countdown-bar h-full bg-amber-300" />
        </div>
      </div>
    </div>
  );
}
