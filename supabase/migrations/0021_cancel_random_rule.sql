-- Carta de regla 'cancel_random': al revelar la ronda, el servidor sortea un
-- valor aleatorio entre 3 y 9 y todas las cartas con ese valor se cancelan.
-- El valor sorteado se incluye en el payload del resultado (`random_cancel_value`)
-- para que el cliente pueda animar la "ruleta" antes de mostrar las cartas.
-- La cancelación por duplicado sigue aplicando sobre el resto.

set search_path = public, pg_temp;

-- 1. CHECK de round_rule_picks incluye 'cancel_random' ---------------------
alter table public.round_rule_picks drop constraint if exists round_rule_picks_rule_kind_check;
alter table public.round_rule_picks
  add constraint round_rule_picks_rule_kind_check
  check (rule_kind in (
    'subtract','no_cancel','swap',
    'add_right','add_left','sub_right','sub_left',
    'cancel_even','cancel_odd',
    'none',
    'rotate_right','rotate_left',
    'double_low',
    'cancel_random'
  ));

-- 2. submit_rule_pick valida la nueva regla -------------------------------
create or replace function public.submit_rule_pick(p_round_id uuid, p_rule_kind text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_round public.rounds%rowtype;
  v_player_id uuid;
  v_hand text[];
  v_existing text;
  v_pos int;
begin
  if p_rule_kind not in (
    'subtract','no_cancel','swap',
    'add_right','add_left','sub_right','sub_left',
    'cancel_even','cancel_odd',
    'none',
    'rotate_right','rotate_left',
    'double_low',
    'cancel_random'
  ) then
    raise exception 'invalid rule';
  end if;
  select * into v_round from public.rounds where rounds.id = p_round_id;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then raise exception 'round closed'; end if;

  select p.id into v_player_id from public.players p
    where p.room_id = v_round.room_id and p.user_id = v_uid;
  if v_player_id is null then raise exception 'not in room'; end if;
  if v_player_id <> v_round.michudice_player_id then
    raise exception 'only michudice can pick rule';
  end if;

  select hand into v_hand from public.player_rule_hands where player_id = v_player_id for update;
  if v_hand is null then raise exception 'no rule hand'; end if;

  select rule_kind into v_existing from public.round_rule_picks where round_id = p_round_id;
  if found then
    v_hand := array_append(v_hand, v_existing);
  end if;

  v_pos := array_position(v_hand, p_rule_kind);
  if v_pos is null then raise exception 'rule not in hand'; end if;
  v_hand := v_hand[1:v_pos-1] || v_hand[v_pos+1:array_length(v_hand,1)];

  update public.player_rule_hands set hand = v_hand where player_id = v_player_id;
  update public.players set rule_hand_size = coalesce(array_length(v_hand,1), 0)
    where id = v_player_id;

  insert into public.round_rule_picks(round_id, player_id, rule_kind)
    values (p_round_id, v_player_id, p_rule_kind)
    on conflict (round_id) do update
      set player_id = excluded.player_id,
          rule_kind = excluded.rule_kind,
          picked_at = now();
end $$;

-- 3. build_rule_deck incluye 'cancel_random' -------------------------------
drop function if exists public.build_rule_deck(int);
drop function if exists public.build_rule_deck(int, text);
create function public.build_rule_deck(p_player_count int, p_mode text default 'classic')
returns text[]
language plpgsql immutable as $$
declare
  v_kinds text[] := array[
    'subtract','no_cancel','swap',
    'add_right','add_left','sub_right','sub_left',
    'cancel_even','cancel_odd',
    'none',
    'rotate_right','rotate_left',
    'double_low',
    'cancel_random'
  ];
  v_subtract_kinds text[] := array['subtract','sub_right','sub_left'];
  v_kind text;
  v_count int;
  v_deck text[] := '{}';
begin
  foreach v_kind in array v_kinds loop
    v_count := case
      when p_mode = 'classic'  then greatest(5, p_player_count + 1)
      when p_mode = 'single'   then 1
      when p_mode = 'negative' then case when v_kind = any(v_subtract_kinds) then 6 else 3 end
      when p_mode = 'positive' then case when v_kind = any(v_subtract_kinds) then 1 else 3 end
      when p_mode = 'pairs'    then 2
      else greatest(5, p_player_count + 1)
    end;
    if v_count > 0 then
      v_deck := v_deck || array(select v_kind from generate_series(1, v_count));
    end if;
  end loop;
  return v_deck;
end $$;

-- 4. score_picks con soporte para 'cancel_random' --------------------------
-- Nueva firma: además del picks/rule recibe p_random_cancel (3..9 o null).
-- Cuando la regla es 'cancel_random', toda carta con valor = p_random_cancel
-- se cancela; el resto sigue el flujo normal (duplicados, escalera, etc.).
-- El payload de salida incluye 'random_cancel_value' para el cliente.
drop function if exists public.score_picks(jsonb);
drop function if exists public.score_picks(jsonb, text);
drop function if exists public.score_picks(jsonb, text, int);
create function public.score_picks(
  p_picks jsonb,
  p_rule text default null,
  p_random_cancel int default null
)
returns jsonb
language plpgsql immutable as $$
declare
  v_rule text := nullif(p_rule, 'none');

  v_canceled int[] := '{}';
  v_unique_values int[] := '{}';
  v_unique_picks jsonb := '[]'::jsonb;
  v_ladders jsonb := '[]'::jsonb;
  v_deltas jsonb := '[]'::jsonb;
  v_swap jsonb := null;
  v_value int;
  v_count int;
  v_n int; v_i int; v_j int; v_idx int;
  v_run_cards int[];
  v_run_sum int;
  v_lowest_card int;
  v_lowest_owner uuid;
  v_pick record;
  v_no_cancel boolean := (v_rule = 'no_cancel');
  v_sign int := case when v_rule = 'subtract' then -1 else 1 end;
  v_cancel_even boolean := (v_rule = 'cancel_even');
  v_cancel_odd  boolean := (v_rule = 'cancel_odd');
  v_cancel_random boolean := (v_rule = 'cancel_random');
  v_random_value int := case when v_rule = 'cancel_random' then p_random_cancel else null end;
  v_parity_cancel boolean;
  v_random_cancel_hit boolean;
  v_low_value int;
  v_high_value int;
  v_low_owner uuid;
  v_high_owner uuid;
  v_unique_len int;
  v_neighbor_rule boolean := v_rule in ('add_right','add_left','sub_right','sub_left');
  v_dir int;
  v_n_sign int;
  v_seated jsonb := '[]'::jsonb;
  v_seat_len int;
  v_unique_ids uuid[] := '{}';
  v_seat_idx int;
  v_me_id uuid;
  v_neighbor_pos int;
  v_neighbor_id uuid;
  v_neighbor_value int;
  v_rotate_dir int := case when v_rule = 'rotate_right' then 1
                           when v_rule = 'rotate_left'  then -1
                           else 0 end;
  v_working jsonb;
  v_source_idx int;
  v_rot_seated jsonb;
  v_rot_len int;
  v_rotated jsonb := '[]'::jsonb;
  v_double_low boolean := (v_rule = 'double_low');
  v_min_unique int;
  v_multiplier int;
begin
  if v_rotate_dir <> 0 then
    select coalesce(jsonb_agg(e order by (e->>'seat')::int asc), '[]'::jsonb)
      into v_rot_seated
      from jsonb_array_elements(p_picks) e
      where e ? 'seat';
    v_rot_len := jsonb_array_length(v_rot_seated);
    if v_rot_len > 1 then
      for v_seat_idx in 0..(v_rot_len - 1) loop
        v_source_idx := ((v_seat_idx - v_rotate_dir) % v_rot_len + v_rot_len) % v_rot_len;
        v_rotated := v_rotated || jsonb_build_object(
          'player_id', (v_rot_seated->v_seat_idx->>'player_id')::uuid,
          'card_value', (v_rot_seated->v_source_idx->>'card_value')::int,
          'seat', (v_rot_seated->v_seat_idx->>'seat')::int
        );
      end loop;
      v_working := v_rotated;
    else
      v_working := p_picks;
    end if;
  else
    v_working := p_picks;
  end if;

  for v_value in 3..9 loop
    select count(*) into v_count
      from jsonb_array_elements(v_working) e
      where (e->>'card_value')::int = v_value;

    v_parity_cancel := (v_cancel_even and v_value % 2 = 0)
                    or (v_cancel_odd  and v_value % 2 = 1);
    v_random_cancel_hit := v_cancel_random and v_random_value is not null
                        and v_value = v_random_value;

    if (v_parity_cancel or v_random_cancel_hit) and v_count >= 1 then
      v_canceled := array_append(v_canceled, v_value);
    elsif v_count = 1 then
      v_unique_values := array_append(v_unique_values, v_value);
    elsif v_count > 1 then
      if v_no_cancel then
        v_unique_values := array_append(v_unique_values, v_value);
      else
        v_canceled := array_append(v_canceled, v_value);
      end if;
    end if;
  end loop;

  v_min_unique := v_unique_values[1];

  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(v_working) e
      order by (e->>'card_value')::int asc
  loop
    if v_no_cancel and not (
      (v_cancel_even and v_pick.card_value % 2 = 0)
      or (v_cancel_odd and v_pick.card_value % 2 = 1)
      or (v_cancel_random and v_random_value is not null and v_pick.card_value = v_random_value)
    ) then
      v_unique_picks := v_unique_picks || jsonb_build_object(
        'player_id', v_pick.player_id, 'card_value', v_pick.card_value
      );
    elsif (not v_no_cancel) and v_pick.card_value = any(v_unique_values) then
      v_unique_picks := v_unique_picks || jsonb_build_object(
        'player_id', v_pick.player_id, 'card_value', v_pick.card_value
      );
    end if;
  end loop;

  if v_rule = 'swap' then
    v_unique_len := jsonb_array_length(v_unique_picks);
    if v_unique_len >= 2 then
      v_low_value  := (v_unique_picks->0->>'card_value')::int;
      v_high_value := (v_unique_picks->(v_unique_len - 1)->>'card_value')::int;
      v_low_owner  := (v_unique_picks->0->>'player_id')::uuid;
      v_high_owner := (v_unique_picks->(v_unique_len - 1)->>'player_id')::uuid;
      if v_low_value <> v_high_value then
        v_unique_picks := jsonb_set(
          v_unique_picks, '{0}',
          jsonb_build_object('player_id', v_high_owner, 'card_value', v_low_value)
        );
        v_unique_picks := jsonb_set(
          v_unique_picks, array[(v_unique_len - 1)::text],
          jsonb_build_object('player_id', v_low_owner, 'card_value', v_high_value)
        );
        v_swap := jsonb_build_object(
          'low_value', v_low_value,
          'high_value', v_high_value,
          'low_original_player_id', v_low_owner,
          'high_original_player_id', v_high_owner
        );
      end if;
    end if;
  end if;

  v_n := coalesce(array_length(v_unique_values, 1), 0);
  v_i := 1;
  while v_i <= v_n loop
    v_j := v_i;
    while v_j < v_n and v_unique_values[v_j + 1] = v_unique_values[v_j] + 1 loop
      v_j := v_j + 1;
    end loop;

    if (v_j - v_i + 1) >= 3 then
      v_run_cards := '{}';
      for v_idx in v_i..v_j loop
        v_run_cards := array_append(v_run_cards, v_unique_values[v_idx]);
      end loop;
      v_run_sum := (select sum(x) from unnest(v_run_cards) x);
      v_lowest_card := v_run_cards[1];

      select (e->>'player_id')::uuid into v_lowest_owner
        from jsonb_array_elements(v_unique_picks) e
        where (e->>'card_value')::int = v_lowest_card limit 1;

      v_ladders := v_ladders || jsonb_build_object(
        'cards', to_jsonb(v_run_cards),
        'sum', v_run_sum * v_sign,
        'winner_id', v_lowest_owner
      );
      v_i := v_j + 1;
    else
      v_i := v_i + 1;
    end if;
  end loop;

  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(v_unique_picks) e
  loop
    v_multiplier := case
      when v_double_low and v_pick.card_value = v_min_unique then 2
      else 1
    end;
    v_deltas := v_deltas || jsonb_build_object(
      'player_id', v_pick.player_id,
      'points', v_pick.card_value * v_sign * v_multiplier,
      'reason', 'unique'
    );
  end loop;

  for v_pick in
    select (e->>'winner_id')::uuid as player_id, (e->>'sum')::int as points
      from jsonb_array_elements(v_ladders) e
  loop
    if v_pick.player_id is not null then
      v_deltas := v_deltas || jsonb_build_object(
        'player_id', v_pick.player_id, 'points', v_pick.points, 'reason', 'ladder'
      );
    end if;
  end loop;

  if v_neighbor_rule then
    v_dir := case when v_rule in ('add_right','sub_right') then 1 else -1 end;
    v_n_sign := case when v_rule in ('sub_right','sub_left') then -1 else 1 end;

    for v_pick in
      select (e->>'player_id')::uuid as player_id from jsonb_array_elements(v_unique_picks) e
    loop
      v_unique_ids := array_append(v_unique_ids, v_pick.player_id);
    end loop;

    select coalesce(jsonb_agg(e order by (e->>'seat')::int asc), '[]'::jsonb)
      into v_seated
      from jsonb_array_elements(v_working) e
      where e ? 'seat';
    v_seat_len := jsonb_array_length(v_seated);

    if v_seat_len > 0 then
      for v_seat_idx in 0..(v_seat_len - 1) loop
        v_me_id := (v_seated->v_seat_idx->>'player_id')::uuid;
        if v_me_id = any(v_unique_ids) then
          v_neighbor_pos := ((v_seat_idx + v_dir) % v_seat_len + v_seat_len) % v_seat_len;
          v_neighbor_id := (v_seated->v_neighbor_pos->>'player_id')::uuid;
          if v_neighbor_id = any(v_unique_ids) then
            v_neighbor_value := (v_seated->v_neighbor_pos->>'card_value')::int;
            v_deltas := v_deltas || jsonb_build_object(
              'player_id', v_me_id,
              'points', v_neighbor_value * v_n_sign,
              'reason', 'neighbor'
            );
          end if;
        end if;
      end loop;
    end if;
  end if;

  return jsonb_build_object(
    'canceled', to_jsonb(v_canceled),
    'unique_picks', v_unique_picks,
    'ladders', v_ladders,
    'deltas', v_deltas,
    'rule', coalesce(v_rule, 'normal'),
    'swap', v_swap,
    'random_cancel_value', v_random_value
  );
end $$;

-- 5. reveal_round: sortea el valor y lo pasa a score_picks -----------------
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
  v_drawn text;
  v_remaining text[];
  v_random_cancel int := null;
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

  -- Inyecta seat en cada pick (reglas de vecino y rotación lo necesitan).
  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', rp.player_id,
    'card_value', rp.card_value,
    'seat', p.seat
  )), '[]'::jsonb) into v_picks
  from public.round_picks rp
  join public.players p on p.id = rp.player_id
  where rp.round_id = p_round_id;

  if v_rule = 'cancel_random' then
    v_random_cancel := 3 + floor(random() * 7)::int;  -- [3..9]
  end if;

  v_result := public.score_picks(v_picks, v_rule, v_random_cancel);
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

  -- Reponer carta de regla al Michudice
  select hand into v_michudice_hand from public.player_rule_hands
    where player_id = v_round.michudice_player_id for update;
  v_room_deck := v_room.rule_deck;

  if coalesce(array_length(v_room_deck, 1), 0) > 0 then
    v_drawn := v_room_deck[1];
    v_michudice_hand := array_append(v_michudice_hand, v_drawn);
    v_remaining := array(
      select v_room_deck[i]
      from generate_series(2, array_length(v_room_deck, 1)) i
    );
    update public.rooms set rule_deck = coalesce(v_remaining, '{}') where id = v_room.id;
    update public.player_rule_hands set hand = v_michudice_hand
      where player_id = v_round.michudice_player_id;
    update public.players set rule_hand_size = coalesce(array_length(v_michudice_hand, 1), 0)
      where id = v_round.michudice_player_id;
  end if;

  return true;
end $$;
