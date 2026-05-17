// Tipos de las filas de Supabase. Mantener sincronizado con supabase/migrations/0001_init.sql.

export type RoomStatus = "lobby" | "in_progress" | "finished";
export type RoundStatus = "picking" | "revealed" | "scored";
export type DeckMode = "classic" | "single" | "negative" | "positive" | "pairs";
export type RuleKind =
  | "subtract"
  | "no_cancel"
  | "swap"
  | "add_right"
  | "add_left"
  | "sub_right"
  | "sub_left"
  | "cancel_even"
  | "cancel_odd"
  | "none"
  | "rotate_right"
  | "rotate_left"
  | "double_low";

export interface RoomRow {
  id: string;
  code: string;
  status: RoomStatus;
  host_id: string;
  max_players: number;
  michudice_target: number;
  current_round: number;
  current_michudice: string | null;
  rule_deck: RuleKind[];
  deck_mode: DeckMode;
  created_at: string;
  finished_at: string | null;
}

export interface PlayerRow {
  id: string;
  room_id: string;
  user_id: string;
  name: string;
  seat: number;
  score: number;
  michudice_count: number;
  hand_size: number;
  rule_hand_size: number;
  joined_at: string;
}

export interface PlayerHandRow {
  player_id: string;
  hand: number[];
}

export interface PlayerRuleHandRow {
  player_id: string;
  hand: RuleKind[];
}

export interface RoundRow {
  id: string;
  room_id: string;
  round_number: number;
  michudice_player_id: string;
  status: RoundStatus;
  rule_played: RuleKind | null;
  revealed_at: string | null;
  scored_at: string | null;
}

export interface RoundRulePickRow {
  round_id: string;
  player_id: string;
  rule_kind: RuleKind;
  picked_at: string;
}

export interface RoundPickRow {
  id: string;
  round_id: string;
  player_id: string;
  card_value: number;
  picked_at: string;
}

export interface RoundResultRow {
  id: string;
  round_id: string;
  payload: {
    canceled: number[];
    unique_picks: { player_id: string; card_value: number }[];
    ladders: { cards: number[]; sum: number; winner_id: string }[];
    deltas: {
      player_id: string;
      points: number;
      reason: "unique" | "ladder" | "neighbor";
    }[];
    rule: RuleKind | "normal";
    swap?: {
      low_value: number;
      high_value: number;
      low_original_player_id: string;
      high_original_player_id: string;
    } | null;
  };
  created_at: string;
}
