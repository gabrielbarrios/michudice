-- Reciclaje del mazo de cartas de regla.
-- Cuando el mazo central (rooms.rule_deck) se vacía, las cartas jugadas en
-- rondas anteriores se reshufflean y vuelven a formar el mazo, garantizando
-- que el Michudice de turno siempre tenga cartas para reponer su mano.

set search_path = public, pg_temp;

alter table public.rooms
  add column if not exists rule_discard text[] not null default '{}';

drop function if exists public.reveal_round(uuid);
create or replace function public.reveal_round(p_round_id uuid)
returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_round public.rounds%rowtype;
  v_room public.rooms%rowtype;
  v_player_count int;
  v_pick_count int;
  v_picks jsonb;
  v_rule text;
  v_result jsonb;
  v_deltas jsonb;
  v_delta record;
  v_michudice_hand text[];
  v_room_deck text[];
  v_room_discard text[];
  v_drawn text;
  v_remaining text[];
begin
  select * into v_round from public.rounds where rounds.id = p_round_id for update;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then return false; end if;

  select * into v_room from public.rooms where rooms.id = v_round.room_id for update;

  select count(*) into v_player_count from public.players where players.room_id = v_room.id;
  select count(*) into v_pick_count from public.round_picks where round_id = p_round_id;
  if v_pick_count < v_player_count then return false; end if;

  select rule_kind into v_rule from public.round_rule_picks where round_id = p_round_id;
  if v_rule is null then return false; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', player_id, 'card_value', card_value
  )), '[]'::jsonb) into v_picks
  from public.round_picks where round_id = p_round_id;

  v_result := public.score_picks(v_picks, v_rule);
  v_deltas := v_result -> 'deltas';

  update public.rounds set status = 'revealed', revealed_at = now(), rule_played = v_rule
    where id = p_round_id;

  for v_delta in
    select * from jsonb_to_recordset(v_deltas) as x(player_id uuid, points int)
  loop
    update public.players set score = score + v_delta.points where id = v_delta.player_id;
  end loop;

  update public.players set michudice_count = michudice_count + 1
    where id = v_round.michudice_player_id;

  insert into public.round_results(round_id, payload) values (p_round_id, v_result);
  update public.rounds set status = 'scored', scored_at = now() where id = p_round_id;

  -- 1) la carta de regla recién jugada va al discard
  v_room_discard := array_append(coalesce(v_room.rule_discard, '{}'), v_rule);

  -- 2) si el mazo está vacío, mezclamos el discard y lo convertimos en mazo
  v_room_deck := coalesce(v_room.rule_deck, '{}');
  if coalesce(array_length(v_room_deck, 1), 0) = 0 then
    v_room_deck := coalesce(public.shuffle_text(v_room_discard), '{}');
    v_room_discard := '{}';
  end if;

  -- 3) reponer carta al Michudice del mazo (si hay)
  select hand into v_michudice_hand from public.player_rule_hands
    where player_id = v_round.michudice_player_id for update;

  if coalesce(array_length(v_room_deck, 1), 0) > 0 then
    v_drawn := v_room_deck[1];
    v_michudice_hand := array_append(coalesce(v_michudice_hand, '{}'), v_drawn);
    v_remaining := array(
      select v_room_deck[i]
      from generate_series(2, array_length(v_room_deck, 1)) i
    );
    v_room_deck := coalesce(v_remaining, '{}');

    update public.player_rule_hands set hand = v_michudice_hand
      where player_id = v_round.michudice_player_id;
    update public.players set rule_hand_size = coalesce(array_length(v_michudice_hand, 1), 0)
      where id = v_round.michudice_player_id;
  end if;

  -- 4) persistir mazo y discard finales
  update public.rooms
    set rule_deck = v_room_deck,
        rule_discard = v_room_discard
    where id = v_room.id;

  return true;
end $$;
