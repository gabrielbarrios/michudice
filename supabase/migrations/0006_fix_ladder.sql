-- Fix: score_picks calculaba mal cuando la escalera no empezaba en la primera
-- carta única ordenada. El slicing de Postgres preserva la cota inferior, así
-- que v_run[1] devolvía NULL para escaleras que no arrancaban en el índice 1,
-- y entonces nadie quedaba marcado como "dentro de escalera" → todos sumaban.
-- Esta versión recorre v_unique_values por índice explícito y construye el run
-- como un array reindexado desde 1.

drop function if exists score_picks(jsonb);
create or replace function score_picks(p_picks jsonb)
returns jsonb
language plpgsql immutable as $$
declare
  v_canceled int[] := '{}';
  v_unique_values int[] := '{}';
  v_unique_picks jsonb := '[]'::jsonb;
  v_ladders jsonb := '[]'::jsonb;
  v_deltas jsonb := '[]'::jsonb;
  v_in_ladder uuid[] := '{}';
  v_value int;
  v_count int;
  v_n int;
  v_i int;
  v_j int;
  v_idx int;
  v_run_cards int[];
  v_run_sum int;
  v_lowest_card int;
  v_lowest_owner uuid;
  v_card_val int;
  v_owner uuid;
  v_pick record;
begin
  -- 1) Conteo por valor: cancelados vs únicos (orden creciente)
  for v_value in 3..9 loop
    select count(*) into v_count
      from jsonb_array_elements(p_picks) e
      where (e->>'card_value')::int = v_value;
    if v_count = 1 then
      v_unique_values := array_append(v_unique_values, v_value);
    elsif v_count > 1 then
      v_canceled := array_append(v_canceled, v_value);
    end if;
  end loop;

  -- 2) Picks únicos (con dueño)
  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(p_picks) e
  loop
    if v_pick.card_value = any(v_unique_values) then
      v_unique_picks := v_unique_picks || jsonb_build_object(
        'player_id', v_pick.player_id, 'card_value', v_pick.card_value
      );
    end if;
  end loop;

  -- 3) Escaleras: barrer v_unique_values y construir runs reindexados
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
        where (e->>'card_value')::int = v_lowest_card
        limit 1;

      v_ladders := v_ladders || jsonb_build_object(
        'cards', to_jsonb(v_run_cards),
        'sum', v_run_sum,
        'winner_id', v_lowest_owner
      );

      -- Marcar a TODOS los dueños de cartas dentro del run (incluso al ganador)
      for v_card_val in select unnest(v_run_cards) loop
        select (e->>'player_id')::uuid into v_owner
          from jsonb_array_elements(v_unique_picks) e
          where (e->>'card_value')::int = v_card_val
          limit 1;
        if v_owner is not null then
          v_in_ladder := array_append(v_in_ladder, v_owner);
        end if;
      end loop;

      v_i := v_j + 1;
    else
      v_i := v_i + 1;
    end if;
  end loop;

  -- 4) Deltas: únicos fuera de escalera + suma para el ganador de cada escalera
  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(v_unique_picks) e
  loop
    if not (v_pick.player_id = any(v_in_ladder)) then
      v_deltas := v_deltas || jsonb_build_object(
        'player_id', v_pick.player_id, 'points', v_pick.card_value, 'reason', 'unique'
      );
    end if;
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
    'deltas', v_deltas
  );
end $$;
