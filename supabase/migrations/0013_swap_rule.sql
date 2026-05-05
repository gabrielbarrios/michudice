-- Carta de regla 'swap': el dueño de la carta única más baja y el de la más
-- alta intercambian valores para sumar puntos. La escalera se detecta sobre
-- los valores efectivos (post-swap) y el bono va a quien quede con el valor
-- más bajo de la escalera. Sigue aplicando la cancelación normal de iguales.

set search_path = public, pg_temp;

-- 1. Aceptar 'swap' en round_rule_picks ----------------------------------
alter table public.round_rule_picks drop constraint if exists round_rule_picks_rule_kind_check;
alter table public.round_rule_picks
  add constraint round_rule_picks_rule_kind_check
  check (rule_kind in ('subtract','no_cancel','swap'));

-- 2. build_rule_deck incluye 'swap' -------------------------------------
create or replace function public.build_rule_deck(p_player_count int) returns text[]
language sql immutable as $$
  with n as (select greatest(5, p_player_count + 1) as v)
  select array_agg(card) from (
    select 'subtract'::text as card from n, generate_series(1, n.v)
    union all
    select 'no_cancel' from n, generate_series(1, n.v)
    union all
    select 'swap' from n, generate_series(1, n.v)
  ) t;
$$;

-- 3. submit_rule_pick acepta 'swap' -------------------------------------
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
  if p_rule_kind not in ('subtract','no_cancel','swap') then raise exception 'invalid rule'; end if;
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

-- 4. score_picks con soporte para 'swap' --------------------------------
drop function if exists public.score_picks(jsonb);
drop function if exists public.score_picks(jsonb, text);
create or replace function public.score_picks(p_picks jsonb, p_rule text default null)
returns jsonb
language plpgsql immutable as $$
declare
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
  v_no_cancel boolean := (p_rule = 'no_cancel');
  v_sign int := case when p_rule = 'subtract' then -1 else 1 end;
  v_low_value int;
  v_high_value int;
  v_low_owner uuid;
  v_high_owner uuid;
  v_unique_len int;
begin
  for v_value in 3..9 loop
    select count(*) into v_count
      from jsonb_array_elements(p_picks) e
      where (e->>'card_value')::int = v_value;
    if v_count = 1 then
      v_unique_values := array_append(v_unique_values, v_value);
    elsif v_count > 1 then
      if v_no_cancel then
        v_unique_values := array_append(v_unique_values, v_value);
      else
        v_canceled := array_append(v_canceled, v_value);
      end if;
    end if;
  end loop;

  -- Construir unique_picks ordenados por card_value asc.
  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(p_picks) e
      order by (e->>'card_value')::int asc
  loop
    if v_no_cancel or (v_pick.card_value = any(v_unique_values)) then
      v_unique_picks := v_unique_picks || jsonb_build_object(
        'player_id', v_pick.player_id, 'card_value', v_pick.card_value
      );
    end if;
  end loop;

  -- Aplicar swap antes de detectar la escalera.
  if p_rule = 'swap' then
    v_unique_len := jsonb_array_length(v_unique_picks);
    if v_unique_len >= 2 then
      v_low_value  := (v_unique_picks->0->>'card_value')::int;
      v_high_value := (v_unique_picks->(v_unique_len - 1)->>'card_value')::int;
      v_low_owner  := (v_unique_picks->0->>'player_id')::uuid;
      v_high_owner := (v_unique_picks->(v_unique_len - 1)->>'player_id')::uuid;

      if v_low_value <> v_high_value then
        -- Reemplaza el primer y último elemento con dueños intercambiados.
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

  -- Escaleras sobre los valores efectivos (idénticos a v_unique_values
  -- porque el swap solo cambia dueños, no valores presentes).
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
    v_deltas := v_deltas || jsonb_build_object(
      'player_id', v_pick.player_id, 'points', v_pick.card_value * v_sign, 'reason', 'unique'
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

  return jsonb_build_object(
    'canceled', to_jsonb(v_canceled),
    'unique_picks', v_unique_picks,
    'ladders', v_ladders,
    'deltas', v_deltas,
    'rule', coalesce(p_rule, 'normal'),
    'swap', v_swap
  );
end $$;
