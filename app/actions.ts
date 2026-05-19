"use server";

import { z } from "zod";
import { redirect } from "next/navigation";
import type { SupabaseClient } from "@supabase/supabase-js";
import { createServerSupabase } from "@/lib/supabase/server";
import { createServiceSupabase } from "@/lib/supabase/service";

const NameSchema = z.string().trim().min(1).max(24);
const CodeSchema = z.string().trim().min(4).max(8).transform((s) => s.toUpperCase());
const DeckModeSchema = z
  .enum(["classic", "single", "negative", "positive", "pairs"])
  .default("classic");

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
  const deckMode = DeckModeSchema.parse(
    formData.get("deck_mode") ?? "classic",
  );
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { data, error } = await supabase.rpc("create_room", {
    p_name: name,
    p_deck_mode: deckMode,
  });
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

const RuleSchema = z.enum([
  "subtract",
  "no_cancel",
  "swap",
  "add_right",
  "add_left",
  "sub_right",
  "sub_left",
  "cancel_even",
  "cancel_odd",
  "none",
  "rotate_right",
  "rotate_left",
  "double_low",
  "cancel_random",
]);

export async function submitRulePickAction(roundId: string, ruleKind: string) {
  const rule = RuleSchema.parse(ruleKind);
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("submit_rule_pick", {
    p_round_id: roundId,
    p_rule_kind: rule,
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

export async function redealRuleHandsAction(roomId: string) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { error } = await supabase.rpc("redeal_rule_hands", { p_room_id: roomId });
  if (error) throw new Error(error.message);
}

// Bots ---------------------------------------------------------------------

const BOT_NAMES = [
  "Garfield", "Mishi", "Tom", "Salem", "Felix", "Luna",
  "Whiskers", "Cleo", "Sushi", "Mochi", "Pelusa", "Bigotes",
];

function pickRandom<T>(arr: ReadonlyArray<T>): T {
  return arr[Math.floor(Math.random() * arr.length)];
}

// Solo el host humano puede agregar bots. Verificamos con sesión normal
// y luego invocamos add_bot vía service role (la RPC no valida auth.uid()).
export async function addBotAction(roomId: string) {
  const supabase = createServerSupabase();
  await ensureAuth(supabase);
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) throw new Error("not authenticated");

  const { data: room, error: roomErr } = await supabase
    .from("rooms")
    .select("id, host_id, status, max_players")
    .eq("id", roomId)
    .single();
  if (roomErr || !room) throw new Error(roomErr?.message ?? "room not found");
  if (room.host_id !== user.user.id) throw new Error("only host can add bots");
  if (room.status !== "lobby") throw new Error("game already started");

  const { data: existing } = await supabase
    .from("players")
    .select("name")
    .eq("room_id", roomId);
  const taken = new Set((existing ?? []).map((p) => p.name));
  const free = BOT_NAMES.filter((n) => !taken.has(n));
  const base = free.length > 0 ? pickRandom(free) : pickRandom(BOT_NAMES);
  const name = free.length > 0 ? base : `${base} ${(existing?.length ?? 0) + 1}`;

  const svc = createServiceSupabase();
  const { error } = await svc.rpc("add_bot", {
    p_room_id: roomId,
    p_name: name,
  });
  if (error) throw new Error(error.message);
}

// Itera bots con pick pendiente y los completa con una carta aleatoria de
// su mano. Si el Michudice es bot y aún no eligió regla, también la elige.
// Idempotente: si todos los bots ya jugaron, no hace nada. Tras enviar las
// picks, intenta reveal_round (que también es idempotente).
export async function runBotsAction(roundId: string) {
  const svc = createServiceSupabase();

  const { data: round, error: roundErr } = await svc
    .from("rounds")
    .select("id, room_id, status, michudice_player_id")
    .eq("id", roundId)
    .single();
  if (roundErr || !round) return;
  if (round.status !== "picking") return;

  const { data: bots } = await svc
    .from("players")
    .select("id")
    .eq("room_id", round.room_id)
    .eq("is_bot", true);
  if (!bots || bots.length === 0) return;

  const { data: existingPicks } = await svc
    .from("round_picks")
    .select("player_id")
    .eq("round_id", roundId);
  const pickedIds = new Set((existingPicks ?? []).map((p) => p.player_id));

  for (const bot of bots) {
    if (pickedIds.has(bot.id)) continue;
    const { data: handRow } = await svc
      .from("player_hands")
      .select("hand")
      .eq("player_id", bot.id)
      .maybeSingle();
    const hand = (handRow?.hand ?? []) as number[];
    if (hand.length === 0) continue;
    const card = pickRandom(hand);
    const { error } = await svc.rpc("bot_submit_pick", {
      p_player_id: bot.id,
      p_round_id: roundId,
      p_card_value: card,
    });
    if (error) {
      // No tirar; el siguiente tick reintentará. Loguear para diagnóstico.
      console.error("bot_submit_pick failed", bot.id, error.message);
    }
  }

  const michudiceIsBot = bots.some((b) => b.id === round.michudice_player_id);
  if (michudiceIsBot) {
    const { data: rulePick } = await svc
      .from("round_rule_picks")
      .select("round_id")
      .eq("round_id", roundId)
      .maybeSingle();
    if (!rulePick) {
      const { data: ruleHandRow } = await svc
        .from("player_rule_hands")
        .select("hand")
        .eq("player_id", round.michudice_player_id)
        .maybeSingle();
      const ruleHand = (ruleHandRow?.hand ?? []) as string[];
      if (ruleHand.length > 0) {
        const rule = pickRandom(ruleHand);
        const { error } = await svc.rpc("bot_submit_rule_pick", {
          p_player_id: round.michudice_player_id,
          p_round_id: roundId,
          p_rule_kind: rule,
        });
        if (error) {
          console.error("bot_submit_rule_pick failed", error.message);
        }
      }
    }
  }

  await svc.rpc("reveal_round", { p_round_id: roundId });
}
