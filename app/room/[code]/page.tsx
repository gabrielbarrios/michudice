import { redirect } from "next/navigation";
import { createServerSupabase } from "@/lib/supabase/server";
import RoomClient from "@/components/RoomClient";
import type { PlayerRow, RoomRow, RoundRow } from "@/types/db";

export const dynamic = "force-dynamic";

export default async function RoomPage({ params }: { params: { code: string } }) {
  const code = params.code.toUpperCase();
  const supabase = createServerSupabase();

  const { data: userData } = await supabase.auth.getUser();
  if (!userData.user) redirect("/");

  const { data: room } = await supabase
    .from("rooms")
    .select("*")
    .eq("code", code)
    .maybeSingle<RoomRow>();
  if (!room) {
    return (
      <main className="mx-auto max-w-md px-6 py-20 text-center">
        <h1 className="text-2xl font-semibold">Sala no encontrada</h1>
        <a className="mt-6 inline-block underline" href="/">
          Volver
        </a>
      </main>
    );
  }

  const { data: players } = await supabase
    .from("players")
    .select("*")
    .eq("room_id", room.id)
    .order("seat", { ascending: true })
    .returns<PlayerRow[]>();

  const me = players?.find((p) => p.user_id === userData.user!.id) ?? null;
  if (!me) {
    return (
      <main className="mx-auto max-w-md px-6 py-20 text-center">
        <h1 className="text-2xl font-semibold">No estás en esta sala</h1>
        <p className="mt-2 text-white/60">
          Pide el código y entra desde la portada.
        </p>
        <a className="mt-6 inline-block underline" href="/">
          Volver
        </a>
      </main>
    );
  }

  const { data: round } = await supabase
    .from("rounds")
    .select("*")
    .eq("room_id", room.id)
    .order("round_number", { ascending: false })
    .limit(1)
    .maybeSingle<RoundRow>();

  return (
    <RoomClient
      initialRoom={room}
      initialPlayers={players ?? []}
      initialRound={round ?? null}
      meId={me.id}
    />
  );
}
