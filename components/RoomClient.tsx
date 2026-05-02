"use client";

import { useEffect, useMemo, useState } from "react";
import { createBrowserSupabase } from "@/lib/supabase/browser";
import type {
  PlayerHandRow,
  PlayerRow,
  RoomRow,
  RoundPickRow,
  RoundResultRow,
  RoundRow,
} from "@/types/db";
import Lobby from "./Lobby";
import GameBoard from "./GameBoard";
import Results from "./Results";

interface Props {
  initialRoom: RoomRow;
  initialPlayers: PlayerRow[];
  initialRound: RoundRow | null;
  meId: string;
}

export default function RoomClient({
  initialRoom,
  initialPlayers,
  initialRound,
  meId,
}: Props) {
  const supabase = useMemo(() => createBrowserSupabase(), []);
  const [room, setRoom] = useState(initialRoom);
  const [players, setPlayers] = useState(initialPlayers);
  const [round, setRound] = useState<RoundRow | null>(initialRound);
  const [picks, setPicks] = useState<RoundPickRow[]>([]);
  const [result, setResult] = useState<RoundResultRow | null>(null);
  const [myHand, setMyHand] = useState<number[]>([]);

  // Cargar picks/result cuando cambia la ronda
  useEffect(() => {
    if (!round) {
      setPicks([]);
      setResult(null);
      return;
    }
    let cancelled = false;
    (async () => {
      const { data: pickRows } = await supabase
        .from("round_picks")
        .select("*")
        .eq("round_id", round.id)
        .returns<RoundPickRow[]>();
      if (!cancelled) setPicks(pickRows ?? []);

      if (round.status === "scored" || round.status === "revealed") {
        const { data: r } = await supabase
          .from("round_results")
          .select("*")
          .eq("round_id", round.id)
          .maybeSingle<RoundResultRow>();
        if (!cancelled) setResult(r ?? null);
      } else {
        setResult(null);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [supabase, round?.id, round?.status]);

  // Realtime: room, players, rounds, picks, results
  useEffect(() => {
    const channel = supabase
      .channel(`room:${room.id}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "rooms", filter: `id=eq.${room.id}` },
        (payload) => {
          if (payload.new) setRoom(payload.new as RoomRow);
        },
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "players", filter: `room_id=eq.${room.id}` },
        async () => {
          const { data } = await supabase
            .from("players")
            .select("*")
            .eq("room_id", room.id)
            .order("seat", { ascending: true })
            .returns<PlayerRow[]>();
          setPlayers(data ?? []);
        },
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "rounds", filter: `room_id=eq.${room.id}` },
        async () => {
          const { data } = await supabase
            .from("rounds")
            .select("*")
            .eq("room_id", room.id)
            .order("round_number", { ascending: false })
            .limit(1)
            .maybeSingle<RoundRow>();
          setRound(data ?? null);
        },
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "round_picks" },
        async (payload) => {
          const newRow = payload.new as RoundPickRow | undefined;
          if (!newRow || !round || newRow.round_id !== round.id) return;
          const { data } = await supabase
            .from("round_picks")
            .select("*")
            .eq("round_id", round.id)
            .returns<RoundPickRow[]>();
          setPicks(data ?? []);
        },
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "round_results" },
        async (payload) => {
          const newRow = payload.new as RoundResultRow | undefined;
          if (!newRow || !round || newRow.round_id !== round.id) return;
          setResult(newRow);
        },
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "player_hands", filter: `player_id=eq.${meId}` },
        (payload) => {
          const row = payload.new as PlayerHandRow | undefined;
          if (row?.hand) setMyHand(row.hand);
        },
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [supabase, room.id, round?.id, meId]);

  // Polling de respaldo: si Realtime no está habilitado en el proyecto Supabase,
  // o se cae la conexión, refrescamos sala/jugadores/ronda cada 2s en lobby
  // y cada 1.5s durante una partida activa.
  useEffect(() => {
    const interval = room.status === "lobby" ? 2000 : 1500;
    const timer = setInterval(async () => {
      const [r, ps, rd] = await Promise.all([
        supabase.from("rooms").select("*").eq("id", room.id).maybeSingle<RoomRow>(),
        supabase
          .from("players")
          .select("*")
          .eq("room_id", room.id)
          .order("seat", { ascending: true })
          .returns<PlayerRow[]>(),
        supabase
          .from("rounds")
          .select("*")
          .eq("room_id", room.id)
          .order("round_number", { ascending: false })
          .limit(1)
          .maybeSingle<RoundRow>(),
      ]);
      if (r.data) setRoom(r.data);
      if (ps.data) setPlayers(ps.data);
      if (rd.data !== undefined) setRound(rd.data);
    }, interval);
    return () => clearInterval(timer);
  }, [supabase, room.id, room.status]);

  // Polling de picks y resultado de la ronda activa
  useEffect(() => {
    if (!round) return;
    const timer = setInterval(async () => {
      const [pks, res] = await Promise.all([
        supabase
          .from("round_picks")
          .select("*")
          .eq("round_id", round.id)
          .returns<RoundPickRow[]>(),
        supabase
          .from("round_results")
          .select("*")
          .eq("round_id", round.id)
          .maybeSingle<RoundResultRow>(),
      ]);
      if (pks.data) setPicks(pks.data);
      if (res.data) setResult(res.data);
    }, 1500);
    return () => clearInterval(timer);
  }, [supabase, round?.id]);

  // Cargar mi mano cuando cambia el estado de la sala (lobby → in_progress)
  // y refrescar periódicamente como fallback de Realtime.
  useEffect(() => {
    let cancelled = false;
    const fetchHand = async () => {
      const { data } = await supabase
        .from("player_hands")
        .select("hand")
        .eq("player_id", meId)
        .maybeSingle<{ hand: number[] }>();
      if (!cancelled) setMyHand(data?.hand ?? []);
    };
    fetchHand();
    const timer = setInterval(fetchHand, 1500);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [supabase, meId, room.status, round?.id]);

  if (room.status === "lobby") {
    return <Lobby room={room} players={players} meId={meId} />;
  }
  if (room.status === "finished") {
    return <Results room={room} players={players} lastResult={result} />;
  }
  return (
    <GameBoard
      room={room}
      players={players}
      round={round}
      picks={picks}
      result={result}
      meId={meId}
      myHand={myHand}
    />
  );
}
