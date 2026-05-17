-- Fix defensivo: garantizar que 'none' (carta "Sin variante") se puntúe
-- exactamente como una ronda sin regla. Si tu Supabase tiene activa una
-- versión vieja de score_picks (anterior a 0016) sin el nullif, esta
-- migración la sobrescribe con la versión correcta.
--
-- Comportamiento esperado para rule_kind = 'none':
--  * Las cartas iguales se cancelan (regla base).
--  * Cada carta única suma su valor a su dueño.
--  * La escalera (3+ valores consecutivos únicos) bonifica al dueño de la
--    carta más baja como en una ronda normal.
--  * Sin signo invertido, sin no_cancel, sin paridad, sin vecino, sin swap,
--    sin rotación.

set search_path = public, pg_temp;

-- 1. Re-asegurar el CHECK de round_rule_picks --------------------------
alter table public.round_rule_picks drop constraint if exists round_rule_picks_rule_kind_check;
alter table public.round_rule_picks
  add constraint round_rule_picks_rule_kind_check
  check (rule_kind in (
    'subtract','no_cancel','swap',
    'add_right','add_left','sub_right','sub_left',
    'cancel_even','cancel_odd',
    'none',
    'rotate_right','rotate_left'
  ));

-- 2. submit_rule_pick valida la lista completa -------------------------
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
    'rotate_right','rotate_left'
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

-- 3. score_picks: 'none' normalizado a null al inicio ------------------
drop function if exists public.score_picks(jsonb);
drop function if exists public.score_picks(jsonb, text);
create function public.score_picks(p_picks jsonb, p_rule text default null)
returns jsonb
language plpgsql immutable as $$
declare
  -- *** Normalización clave: 'none' === sin regla ***
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
  v_parity_cancel boolean;
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
begin
  -- Rotación (sólo si la regla es rotate_*)
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

  -- Cancelación por paridad (cancel_even/odd) o por duplicado (regla base)
  for v_value in 3..9 loop
    select count(*) into v_count
      from jsonb_array_elements(v_working) e
      where (e->>'card_value')::int = v_value;

    v_parity_cancel := (v_cancel_even and v_value % 2 = 0)
                    or (v_cancel_odd  and v_value % 2 = 1);

    if v_parity_cancel and v_count >= 1 then
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

  -- Construir unique_picks ordenadas por card_value asc
  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(v_working) e
      order by (e->>'card_value')::int asc
  loop
    if v_no_cancel and not (
      (v_cancel_even and v_pick.card_value % 2 = 0)
      or (v_cancel_odd and v_pick.card_value % 2 = 1)
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

  -- swap (sólo si la regla es swap)
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

  -- Escalera (igual para todas las reglas, sólo varía el signo)
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

  -- Deltas: carta única (signed) + ladder
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

  -- Bonus de vecino (sólo add_*/sub_*)
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
    'swap', v_swap
  );
end $$;
