"use server";

import { z } from "zod";
import { redirect } from "next/navigation";
import type { SupabaseClient } from "@supabase/supabase-js";
import { createServerSupabase } from "@/lib/supabase/server";

const NameSchema = z.string().trim().min(1).max(24);
const CodeSchema = z.string().trim().min(4).max(8).transform((s) => s.toUpperCase());

// Garantiza una sesión (anónima si hace falta) antes de cualquier RPC.
// Cubre el caso donde el middleware no corrió o la cookie aún no llegó.
async function ensureAuth(supabase: SupabaseClient) {
  const { data } = await supabase.auth.getUser();
  if (data.user) return;
  const { error } = await supabase.auth.signInAnonymously();
  if (error) {
    throw new Error(
      "No se pudo iniciar sesión anónima. Habilita 'Anonymous Sign-Ins' en " +
        "Supabase → Authentication → Providers. Detalle: " +
        error.message,
    );
  }
}

export async function createRoomAction(formData: FormData) {
  const name = NameSchema.parse(formData.get("name"));
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { data, error } = await supabase.rpc("create_room", { p_name: name });
  if (error) throw new Error(error.message);
  const code = data?.[0]?.out_room_code;
  if (!code) throw new Error("no room code returned");
  redirect(`/room/${code}`);
}

export async function joinRoomAction(formData: FormData) {
  const name = NameSchema.parse(formData.get("name"));
  const code = CodeSchema.parse(formData.get("code"));
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("join_room", { p_code: code, p_name: name });
  if (error) throw new Error(error.message);
  redirect(`/room/${code}`);
}

export async function startGameAction(roomId: string) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("start_game", { p_room_id: roomId });
  // Si la sala ya estaba iniciada (por reintento o doble click), no es error real.
  if (error && !/already started/i.test(error.message)) {
    throw new Error(error.message);
  }
}

export async function submitPickAction(roundId: string, cardValue: number) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("submit_pick", {
    p_round_id: roundId,
    p_card_value: cardValue,
  });
  if (error) throw new Error(error.message);
  await supabase.rpc("reveal_round", { p_round_id: roundId });
}

export async function tryRevealAction(roundId: string) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("reveal_round", { p_round_id: roundId });
  if (error) throw new Error(error.message);
}

export async function advanceRoundAction(roundId: string) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("advance_round", { p_round_id: roundId });
  if (error) throw new Error(error.message);
}

export async function redealHandsAction(roomId: string) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("redeal_hands", { p_room_id: roomId });
  if (error) throw new Error(error.message);
}
